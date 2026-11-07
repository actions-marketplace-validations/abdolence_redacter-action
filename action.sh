#!/usr/bin/env bash
# The shell steps of action.yml: `setup` installs redacter and resolves the addons, `run` runs it.
# Inputs arrive as environment variables, never through ${{ }} in a script, so a value cannot
# inject shell code. Kept to bash 3.2, the bash a macOS runner may run it with.
set -euo pipefail

readonly repo="abdolence/redacter-rs"

# A workflow command ends at a new line, so the message is escaped to keep an input value in it
# from starting a command of its own.
fail() {
    local message="$*"
    message=${message//%/%25}
    message=${message//$'\r'/%0D}
    message=${message//$'\n'/%0A}
    printf '::error::%s\n' "$message"
    exit 1
}

list_items() {
    printf '%s\n' "$1" | tr -s ', \t\r\n' '\n' | sed '/^$/d'
}

# Addon names go into the cache key and every name into the command line, so only lower case words
# joined by hyphens pass. redacter itself checks that a redacter or an addon exists.
check_name() {
    case "$2" in
        "" | -* | *[!a-z0-9-]*) fail "$1 has an invalid name '$2'" ;;
    esac
}

# Hashes standard input rather than the named file: GNU sha256sum puts a backslash before the hash
# of a file whose name holds one, as a Windows path does.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"$1" | cut -d ' ' -f 1
    else
        shasum -a 256 <"$1" | cut -d ' ' -f 1
    fi
}

# SHA-256 digests of the archives of the pinned versions, as "<version>/<asset>". An install of a pinned
# version needs no API call and no token, and a replaced release asset is refused. Add the digests of a new
# default `version` of action.yml here, and keep those of the earlier ones.
pinned_sha256() {
    case "$1" in
        0.22.2/redacter-Linux-x86_64.tar.gz) echo 3dfe3e5ece0c9496d527530739c2cb473484a2f7b827c7e36c9cd0e16846a465 ;;
        0.22.2/redacter-Linux-aarch64.tar.gz) echo 8b23ecf7429a7a7756fe41816005a7ac5776afff8515cad44bee85d5c0b60d43 ;;
        0.22.2/redacter-Darwin-aarch64.tar.gz) echo 45303dac15f64b58e8f85f73a9618f3724485d38e248891423fd02c1542d0206 ;;
        0.22.2/redacter-Darwin-x86_64.tar.gz) echo a4225e20290a7cf16bb6d3d7aeed76f8db4e333088b076ffb4adc16575e61b21 ;;
        0.22.2/redacter-Windows-x86_64.zip) echo b72d36b5df9446d58af0769522c8623402e7e07f229a0c8984292bb7a1895162 ;;
        0.22.1/redacter-Linux-x86_64.tar.gz) echo 6eae67ae54f0814778a5046d966675ee2c703028a143b8defbea462e9a03167c ;;
        0.22.1/redacter-Linux-aarch64.tar.gz) echo afac06c33cde9d1c55b901900f1fcbea21d8444fe85bdeb24c953b13fc6d73fb ;;
        0.22.1/redacter-Darwin-aarch64.tar.gz) echo 7c2f7e4b34cf63a00bca9682411f63c365898393bf38ab92e32b320f4b6c1dae ;;
        0.22.1/redacter-Darwin-x86_64.tar.gz) echo 2f56d846a84cbb7d66f559f1acc085c27179349ba60beb5f7802109291a45631 ;;
        0.22.1/redacter-Windows-x86_64.zip) echo aaa9ec55cdaf68f49c7862bbfa0410f128ed8599bbf37332eb5af630cd60ffd9 ;;
    esac
}

setup() {
    case "$INPUT_COMMAND" in
        scan)
            [ -z "$INPUT_DESTINATION" ] || fail "destination is only for the cp command"
            ;;
        cp)
            [ -n "$INPUT_DESTINATION" ] || fail "the cp command needs a destination"
            [ -z "$INPUT_FAIL_ON" ] || fail "fail-on is only for the scan command"
            ;;
        *) fail "command must be scan or cp, got '$INPUT_COMMAND'" ;;
    esac
    case "$INPUT_CACHE" in
        true | false) ;;
        *) fail "cache must be true or false, got '$INPUT_CACHE'" ;;
    esac
    command -v jq >/dev/null 2>&1 || fail "jq is not installed on the runner, the action reads the release and the SARIF report with it"

    local asset bin_name
    case "$RUNNER_OS-$RUNNER_ARCH" in
        Linux-X64) asset=redacter-Linux-x86_64.tar.gz bin_name=redacter ;;
        Linux-ARM64) asset=redacter-Linux-aarch64.tar.gz bin_name=redacter ;;
        macOS-ARM64) asset=redacter-Darwin-aarch64.tar.gz bin_name=redacter ;;
        macOS-X64) asset=redacter-Darwin-x86_64.tar.gz bin_name=redacter ;;
        Windows-X64) asset=redacter-Windows-x86_64.zip bin_name=redacter.exe ;;
        *) fail "$RUNNER_OS $RUNNER_ARCH runners are not supported. Supported: Linux X64 and ARM64, macOS X64 and ARM64, Windows X64" ;;
    esac

    local version=${INPUT_VERSION#v}
    case "$version" in
        "" | [!0-9]* | *[!0-9A-Za-z.+-]*) fail "version must be a redacter release such as 0.22.1, got '$INPUT_VERSION'" ;;
    esac

    local redacters="" redacter
    while IFS= read -r redacter; do
        check_name redacters "$redacter"
        redacters="${redacters:+$redacters,}$redacter"
    done < <(list_items "$INPUT_REDACTERS")
    [ -n "$redacters" ] || fail "redacters needs at least one redacter"

    local addons addon
    case "$INPUT_ADDONS" in
        auto)
            addons="ocr pdf"
            for addon in local-ner local-gliner local-credential-ml; do
                case ",$redacters," in
                    *",$addon,"*) addons="$addons $addon" ;;
                esac
            done
            ;;
        none) addons="" ;;
        *) addons=$INPUT_ADDONS ;;
    esac
    local resolved_addons=""
    while IFS= read -r addon; do
        check_name addons "$addon"
        resolved_addons="${resolved_addons:+$resolved_addons,}$addon"
    done < <(list_items "$addons" | sort -u)

    local tag="v$version" work_dir
    work_dir=$(mktemp -d "$RUNNER_TEMP/redacter.XXXXXX")

    local expected digest_source="pinned in the action"
    expected=$(pinned_sha256 "$version/$asset")
    if [ -z "$expected" ]; then
        digest_source="recorded by GitHub for the release"
        local release_url="https://api.github.com/repos/$repo/releases/tags/$tag"
        # The token reaches curl as a config on standard input, which keeps it off the command line
        # that other users of a self-hosted runner can read.
        if [ -n "$GITHUB_API_TOKEN" ]; then
            printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_API_TOKEN"
        fi | curl -fsSL --retry 3 -K - -H 'Accept: application/vnd.github+json' -o "$work_dir/release.json" "$release_url" ||
            fail "cannot read release $tag from $release_url"

        jq -e --arg asset "$asset" 'any(.assets[]; .name == $asset)' "$work_dir/release.json" >/dev/null ||
            fail "release $tag has no asset $asset"
        expected=$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // empty' "$work_dir/release.json" | tr -d '\r')
        [[ $expected =~ ^sha256:[0-9a-f]{64}$ ]] || fail "release $tag has no SHA-256 digest for $asset, refusing to install it"
        expected=${expected#sha256:}
    fi

    local archive="$work_dir/$asset"
    curl -fsSL --retry 3 -o "$archive" "https://github.com/$repo/releases/download/$tag/$asset" ||
        fail "cannot download $asset of release $tag"
    local actual
    actual=$(sha256_of "$archive")
    [ "$actual" = "$expected" ] || fail "SHA-256 mismatch for $asset: expected $expected, got $actual. Nothing was installed"

    case "$asset" in
        *.zip) unzip -q "$archive" "$bin_name" -d "$work_dir" ;;
        *) tar -xzf "$archive" -C "$work_dir" "$bin_name" ;;
    esac
    echo "Installed redacter $tag from $asset, SHA-256 $digest_source"

    {
        echo "bin=$work_dir/$bin_name"
        echo "addons=$resolved_addons"
        if [ -n "$resolved_addons" ]; then
            echo "addons-dir=$RUNNER_TEMP/redacter-addons"
            # The cache steps of action.yml run only when there is a key, so `cache: false` leaves it out.
            if [ "$INPUT_CACHE" = true ]; then
                echo "addons-cache-key=redacter-addons-$RUNNER_OS-$RUNNER_ARCH-$version-${resolved_addons//,/+}"
            fi
        fi
    } >>"$GITHUB_OUTPUT"
}

# Exits with 0 whatever redacter exits with, after setting the outputs: the next step of the
# action fails on the exit code, so a later step of the job that runs on failure, such as an
# upload of the SARIF report, finds the outputs set.
run() {
    local report_dir
    report_dir=$(mktemp -d "$RUNNER_TEMP/redacter-report.XXXXXX")
    local sarif_file="$report_dir/redacter-$INPUT_COMMAND.sarif"

    local args=("$INPUT_COMMAND") redacter arg
    while IFS= read -r redacter; do
        args+=(--redact "$redacter")
    done < <(list_items "$INPUT_REDACTERS")
    local categories
    categories=$(list_items "$INPUT_CATEGORIES" | paste -sd, -)
    if [ -n "$categories" ]; then
        args+=("--categories=$categories")
    fi
    if [ -n "$INPUT_FAIL_ON" ]; then
        args+=("--fail-on=$INPUT_FAIL_ON")
    fi
    args+=(--unsupported-as-text --report-format=sarif "--report-file=$sarif_file")
    while IFS= read -r arg; do
        case "$arg" in
            --show-values | --show-values=*)
                fail "--show-values is not accepted, it writes the values found to the log of the run, which everyone with read access to the repository can see"
                ;;
        esac
        args+=("$arg")
    done < <(printf '%s\n' "$INPUT_ARGS" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d')
    args+=(-- "$INPUT_PATH")
    if [ "$INPUT_COMMAND" = cp ]; then
        args+=("$INPUT_DESTINATION")
    fi

    if [ -n "$ADDONS_DIR" ]; then
        export REDACTER_ADDONS_DIR="$ADDONS_DIR"
    fi
    local exit_code=0
    "$REDACTER_BIN" "${args[@]}" || exit_code=$?

    echo "exit-code=$exit_code" >>"$GITHUB_OUTPUT"
    if [ -f "$sarif_file" ]; then
        local findings
        findings=$(jq '[.runs[].results[] | select(.level == "error")] | length' "$sarif_file" | tr -d '\r')
        printf 'sarif-file=%s\nfindings=%s\n' "$sarif_file" "$findings" >>"$GITHUB_OUTPUT"
    fi
}

case "$1" in
    setup) setup ;;
    run) run ;;
    *) fail "unknown step '$1'" ;;
esac
