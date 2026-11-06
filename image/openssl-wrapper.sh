#!/bin/bash
set -euo pipefail
# SDM's headless OL9 setup can wait indefinitely for interactive CSR fields.
# Supply a subject only for CSR creation lacking an explicit subject/config.
if [ "${1:-}" = req ]; then
    has_new=false
    has_subject=false
    for arg in "$@"; do
        case "$arg" in
            -new) has_new=true ;;
            -subj|-config) has_subject=true ;;
        esac
    done
    if "$has_new" && ! "$has_subject"; then
        cert_name=${SDM_CERT_HOSTNAME:-$(hostname)}
        if [[ ! "$cert_name" =~ ^[A-Za-z0-9.-]+$ ]]; then
            echo 'Invalid certificate hostname' >&2; exit 1
        fi
        /usr/bin/openssl "$@" -subj "/CN=$cert_name"
        # The vendor Java caller treats EOF before this final prompt as failure.
        # Preserve its final prompt/response exchange after generating the CSR.
        printf 'An optional company name []:' >&2
        IFS= read -r company_name || true
        exit 0
    fi
fi
exec /usr/bin/openssl "$@"
