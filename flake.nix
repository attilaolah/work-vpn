{
  description = "OpenVPN config for work";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux"];
      perSystem = {pkgs, ...}: let
        # This script runs when the VPN connects with --resolved flag
        resolvedUpScript = pkgs.writeShellScript "vpn-up-resolved.sh" ''
          #!${pkgs.runtimeShell}
          set -x

          # This script configures a "split-DNS" setup.
          # - Queries for the domains specified below will be sent to the VPN's DNS servers.
          # - All other queries will use your system's primary, default DNS servers.
          #
          # By not setting this interface as the default route for DNS, we avoid
          # sending all system traffic through the work VPN's DNS.

          # Collect all DNS servers and domains from OpenVPN env vars
          dns_servers=""
          dns_domains=""
          for option in ''${!foreign_option_*}; do
            value="''${!option}"
            if [[ $value == "dhcp-option DNS "* ]]; then
              dns_servers="$dns_servers ''${value#dhcp-option DNS }"
            elif [[ $value == "dhcp-option DOMAIN "* ]]; then
              # Add ~ prefix to mark domain for interface-based routing.
              dns_domains="$dns_domains ~''${value#dhcp-option DOMAIN }"
            fi
          done

          # 1. Set the DNS servers for the interface
          ${pkgs.systemd}/bin/resolvectl dns "$dev" $dns_servers
          # 2. Disable DNS-over-TLS for this interface
          ${pkgs.systemd}/bin/resolvectl dnsovertls "$dev" no
          # 3. Force DNSSEC OFF for this interface
          ${pkgs.systemd}/bin/resolvectl dnssec "$dev" no
          # 4. Set the domains for routing
          ${pkgs.systemd}/bin/resolvectl domain "$dev" $dns_domains
        '';

        # This script runs when the VPN disconnects with --resolved flag
        resolvedDownScript = pkgs.writeShellScript "vpn-down-resolved.sh" ''
          #!${pkgs.runtimeShell}
          set -x
          # Cleanly revert all DNS changes made to the interface
          ${pkgs.systemd}/bin/resolvectl revert "$dev"
        '';
      in {
        packages.default = pkgs.writeShellApplication {
          name = "work-vpn";
          runtimeInputs = with pkgs; [
            bc
            coreutils
            gnugrep
            gnused
            openvpn
            rbw
            systemd
            update-resolv-conf
          ];
          text = ''
            set -euo pipefail

            if command -v doas >/dev/null 2>&1; then
              PREFIX="doas"
            elif command -v sudo >/dev/null 2>&1; then
              PREFIX="sudo"
            else
              PREFIX=""
            fi

            use_resolved=false
            while getopts ":vrs-:" opt; do
              case "$opt" in
                v)
                  # Enable shell debugging.
                  set -x
                  verbose=true
                  ;;
                r)
                  use_resolved=true
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
                    resolved)
                      use_resolved=true
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
            if [ -z "''${OPENVPN_BW_ID:-}" ]; then
              echo "OPENVPN_BW_ID environment variable is not set."
              echo "Store work credentials in Bitwarden and set the UUID in \`.env.local\`."
              exit 2
            fi

            # Ensure RBW is logged in.
            if ! rbw login; then
              echo "Bitwarden login failed. Make sure \`rbw\` is installed and the \`rbw-agent\`"
              echo "is running. Install \`rbw\` and type \`rbw login\` to get started."
              exit 3
            fi

            # Ensure RBW is unlocked.
            if ! rbw unlock; then
              echo "Bitwarden unlock failed. Try unlocking manually by running \`rbw unlock\`."
              exit 4
            fi

            if [ "''${staging:-}" = true ]; then
                OPENVPN_URL="$OPENVPN_URL_STAGE"
            fi

            if [ "''${verbose:-}" = true ]; then
              VERB=3
            else
              VERB=0
            fi

            CREDS_DIR="$(mktemp --directory)"
            CREDS_FIFO="$CREDS_DIR/credentials"
            mkfifo --mode=600 "$CREDS_FIFO"

            cat <<EOF >"$CREDS_FIFO" &
            $(rbw get "$OPENVPN_BW_ID" --field username)
            $(rbw get "$OPENVPN_BW_ID" --field password)
            EOF
            CREDS_PID=$!

            cat <<EOF |
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

            $(
              if [ "''${use_resolved:-}" = true ]; then
                echo '# Update resolv.conf via systemd-resolved.'
                echo 'up "${resolvedUpScript}"'
                echo 'down "${resolvedDownScript}"'
              else
                echo '# Update resolv.conf when connected.'
                echo 'up "${pkgs.update-resolv-conf}/libexec/openvpn/update-resolv-conf"'
                echo 'down "${pkgs.update-resolv-conf}/libexec/openvpn/update-resolv-conf"'
              fi
            )
            script-security 2

            # Access Server:
            verify-x509-name "CN=OpenVPN Server"

            # OpenVPN CA.
            # It should be saved in Bitwarden under the openvpn_client_key field.
            <ca>
            -----BEGIN CERTIFICATE-----
            $(
              rbw get "$OPENVPN_BW_ID" --field openvpn_ca |
                tr ' ' \\n
            )
            -----END CERTIFICATE-----
            </ca>

            # OpenVPN TLS client key.
            # It should be saved in Bitwarden under the openvpn_client_key field.
            <tls-crypt-v2>
            -----BEGIN OpenVPN tls-crypt-v2 client key-----
            $(
              rbw get "$OPENVPN_BW_ID" --field openvpn_tls_client_key |
                tr ' ' \\n
            )
            -----END OpenVPN tls-crypt-v2 client key-----
            </tls-crypt-v2>
            EOF
              $PREFIX openvpn --config /dev/stdin &
            START_PID=$!

            # Clean up temporary files.
            wait $CREDS_PID
            rm "$CREDS_FIFO"
            rmdir "$CREDS_DIR"

            # Wait for 2nd factor prompt:
            CHALLENGE_PAT="CHALLENGE: "
            while [ "$(
              systemd-tty-ask-password-agent --list |
                grep -c "$CHALLENGE_PAT"
            )" -lt 1 ]; do
              sleep 0.2
            done

            RESPONSE="$OPENVPN_CHALLENGE_PREFIX$(
              systemd-tty-ask-password-agent --list |
                grep "$CHALLENGE_PAT" |
                sed --regexp-extended --expression 's/.*?([0-9]+)([x/+-])([0-9]+).*/\1\2\3/g' |
                tr x '*' |
                bc
            )"
            SOCKET="$(
              grep "^Socket=" "$(
                grep --files-with-matches "$CHALLENGE_PAT" /run/systemd/ask-password/ask.*
              )" |
              sed 's/.*=//'
            )"

            echo "$RESPONSE" |
              $PREFIX pkexec "${pkgs.systemd}/lib/systemd/systemd-reply-password" 1 "$SOCKET"

            # Give control back to the OpenVPN process:
            wait $START_PID
          '';
        };
      };
    };
}
