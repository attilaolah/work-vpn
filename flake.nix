{
  description = "OpenVPN config for work";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux"];
      perSystem = {pkgs, ...}: {
        packages.default = with pkgs.lib; let
          ask-password = getExe' pkgs.systemd "systemd-tty-ask-password-agent";
          bc = getExe pkgs.bc;
          cat = getExe' pkgs.coreutils "cat";
          echo = getExe' pkgs.coreutils "echo";
          grep = getExe pkgs.gnugrep;
          mkfifo = getExe' pkgs.coreutils "mkfifo";
          mktemp = getExe' pkgs.coreutils "mktemp";
          openvpn = getExe pkgs.openvpn;
          rbw = getExe pkgs.rbw;
          reply-password = "${pkgs.systemd}/lib/systemd/systemd-reply-password";
          rm = getExe' pkgs.coreutils "rm";
          rmdir = getExe' pkgs.coreutils "rmdir";
          sed = getExe pkgs.gnused;
          sleep = getExe' pkgs.coreutils "sleep";
          tr = getExe' pkgs.coreutils "tr";
          update-resolv-conf = "${pkgs.update-resolv-conf}/libexec/openvpn/update-resolv-conf";
          wc = getExe' pkgs.coreutils "wc";
        in
          pkgs.writeShellScriptBin "work-vpn" ''
            set -euo pipefail

            while getopts ":vs-:" opt; do
              case "$opt" in
                v)
                  # Enable shell debugging.
                  set -x
                  verbose=true
                  ;;
                s)
                  staging=true
                  ;;
                -)
                  case "$OPTARG" in
                    verbose)
                      # Enable shell debugging.
                      set -x
                      verbose=true
                      ;;
                    staging)
                      staging=true
                      ;;
                    *)
                      echo "unknown option: --$OPTARG"
                      exit 1
                      ;;
                  esac
                  ;;
                *)
                  echo "unknown option: -$OPTARG"
                  exit 1
                  ;;
              esac
            done

            # Bitwarden credentials identifier.
            # This is where the VPN username & password are stored.
            if [ -z "''\${OPENVPN_BW_ID:-}" ]; then
              ${echo} "OPENVPN_BW_ID environment variable is not set."
              ${echo} "Store work credentials in Bitwarden and set the UUID in \`.env.local\`."
              exit 2
            fi

            # Ensure RBW is logged in.
            if ! ${rbw} login; then
              ${echo} "Bitwarden login failed. Make sure \`rbw\` is installed and the \`rbw-agent\`"
              ${echo} "is running. Install \`rbw\` and type \`rbw login\` to get started."
              exit 3
            fi

            # Ensure RBW is unlocked.
            if ! ${rbw} unlock; then
              ${echo} "Bitwarden unlock failed. Try unlocking manually by running \`rbw unlock\`."
              exit 4
            fi

            if [ "''\${staging:-}" = true ]; then
                OPENVPN_URL="$OPENVPN_URL_STAGE"
            fi

            if [ "''\${verbose:-}" = true ]; then
              VERB=3
            else
              VERB=0
            fi

            CREDS_DIR="$(${mktemp} --directory)"
            CREDS_FIFO="$CREDS_DIR/credentials"
            ${mkfifo} --mode=600 "$CREDS_FIFO"

            cat <<EOF >$CREDS_FIFO &
            $(${rbw} get $OPENVPN_BW_ID --field username)
            $(${rbw} get $OPENVPN_BW_ID --field password)
            EOF
            CREDS_PID=$!

            ${cat} <<EOF |
            client
            nobind

            remote $OPENVPN_URL 443 tcp
            remote $OPENVPN_URL 1196 udp

            dev tun
            dev-type tun
            remote-cert-tls server

            # openvpn --show-tls
            tls-version-min 1.3

            # openvpn --show-ciphers
            cipher AES-256-GCM
            data-ciphers AES-256-GCM

            auth-user-pass $CREDS_FIFO
            auth-retry interact
            auth-nocache
            reneg-sec 604800

            # Required for 2nd factor.
            push-peer-info

            # Only used for debugging.
            verb $VERB

            # Update resolv.conf when connected.
            # Needed to get internal domains to resolve.
            up ${update-resolv-conf}
            down ${update-resolv-conf}
            script-security 2

            # Access Server:
            verify-x509-name "CN=OpenVPN Server"

            # OpenVPN CA.
            # It should be saved in Bitwarden under the openvpn_client_key field.
            <ca>
            -----BEGIN CERTIFICATE-----
            $(
              ${rbw} get $OPENVPN_BW_ID --field openvpn_ca |
                ${tr} ' ' \\n
            )
            -----END CERTIFICATE-----
            </ca>

            # OpenVPN TLS client key.
            # It should be saved in Bitwarden under the openvpn_client_key field.
            <tls-crypt-v2>
            -----BEGIN OpenVPN tls-crypt-v2 client key-----
            $(
              ${rbw} get $OPENVPN_BW_ID --field openvpn_tls_client_key |
                ${tr} ' ' \\n
            )
            -----END OpenVPN tls-crypt-v2 client key-----
            </tls-crypt-v2>
            EOF
              sudo ${openvpn} --config /dev/stdin &
            START_PID=$!

            # Clean up temporary files.
            wait $CREDS_PID
            ${rm} "$CREDS_FIFO"
            ${rmdir} "$CREDS_DIR"

            # Wait for 2nd factor prompt:
            CHALLENGE_PAT="CHALLENGE: "
            while [ "$(
              ${ask-password} --list |
                ${grep} "$CHALLENGE_PAT" |
                ${wc} -l
            )" -lt 1 ]; do
              ${sleep} 0.2
            done

            RESPONSE="$OPENVPN_CHALLENGE_PREFIX$(
              ${ask-password} --list |
                ${grep} "$CHALLENGE_PAT" |
                ${sed} --regexp-extended --expression 's/.*?([0-9]+)([x/+-])([0-9]+).*/\1\2\3/g' |
                ${tr} x '*' |
                ${bc}
            )"
            SOCKET="$(
              ${grep} "^Socket=" $(
                ${grep} --files-with-matches "$CHALLENGE_PAT" /run/systemd/ask-password/ask.*
              ) |
              ${sed} 's/.*=//'
            )"

            ${echo} "$RESPONSE" |
              sudo pkexec "${reply-password}" 1 "$SOCKET"

            # Give control back to the OpenVPN process:
            wait $START_PID
          '';
      };
    };
}
