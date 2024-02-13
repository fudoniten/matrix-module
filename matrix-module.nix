{ config, lib, pkgs, ... }@toplevel:

with lib;
let
  cfg = config.fudo.services.matrix;

  hostname = config.instance.hostname;

  hostSecrets = config.fudo.secrets.host-secrets."${hostname}";

  openIdConfig = pkgs.writeText "matrix-openid.yaml" (builtins.toJSON {
    oidc_providers = [{
      idp_id = cfg.openid.provider;
      idp_name = cfg.openid.provider-name;
      discover = true;
      issuer = cfg.openid.issuer;
      client_id = cfg.openid.client-id;
      client_secret = cfg.openid.client-secret;
      scopes = [ "openid" "profile" "email" ];
      user_mapping_provider.config = {
        localpart_template = "{{ user.preferred_username }}";
        display_name_template = "{{ user.name|capitalize }}";
      };
    }];
  });

in {
  options.fudo.services.matrix = with types; {
    enable = mkEnableOption "Enable Matrix server.";

    state-directory = mkOption {
      type = str;
      description = "Directory at which to store server state data.";
    };

    server-name = mkOption {
      type = str;
      description = ''
        Hostname at which the server can be reached.

        Also the tag at the end of the username: @user@my-server.com.

        Can be redirected to the actual server. See:

        https://nixos.org/manual/nixos/stable/#module-services-matrix-synapse
      '';
    };

    hostname = mkOption {
      type = str;
      description = "Hostname at which the server can be reached.";
      default = toplevel.config.fudo.services.matrix.server-name;
    };

    port = mkOption {
      type = port;
      description = "Local port to use for Matrix.";
      default = 7520;
    };

    openid = {
      provider = mkOption {
        type = str;
        description = "Name/ID of the authentication provider.";
      };

      provider-name = mkOption {
        type = str;
        description = "Name of the authentication provider.";
      };

      client-id = mkOption {
        type = str;
        description = "OpenID Client ID.";
      };

      client-secret = mkOption {
        type = str;
        description = "OpenID Client Secret.";
      };

      issuer = mkOption {
        type = str;
        description = "OpenID issuer URL.";
      };
    };
  };

  config = mkIf cfg.enable {
    fudo.secrets.host-secrets."${hostname}".matrixOpenIdConfig = {
      source-file = openIdConfig;
      target-file = "/run/matrix/openid.cfg";
      user = config.systemd.services.matrix-synapse.serviceConfig.User;
    };

    systemd = {
      tmpfiles.rules =
        let user = config.systemd.services.matrix-synapse.serviceConfig.User;
        in [
          "d ${cfg.state-directory}/secrets 0700 ${user} root - -"
          "d ${cfg.state-directory}/database 0700 ${user} root - -"
          "d ${cfg.state-directory}/media 0700 ${user} root - -"
        ];
      services.matrix-synapse.serviceConfig.ReadWritePaths =
        [ cfg.state-directory ];
    };

    networking.firewall.allowedTCPPorts = [ 8008 8448 ];

    services = {
      matrix-synapse = {
        enable = true;
        withJemalloc = true;
        settings = {
          server_name = cfg.server-name;
          public_baseurl = "https://${cfg.hostname}";
          dynamic_thumbnails = true;
          max_upload_size = "100M";
          media_store_path = "${cfg.state-directory}/media";
          signing_key_path = "${cfg.state-directory}/secrets/signing.key";
          # Only to trigger the inclusion of oidc deps, actual config is elsewhere
          oidc_providers = [ ];
          jwt_config = {
            enabled = true;
            algorithm = "HS256";
            secret = ''
              -----BEGIN CERTIFICATE-----
              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
              jCunluN2DypxO3PVEWqIUvNhlv0XW9o=
              -----END CERTIFICATE-----
            '';
          };
          listeners = [{
            port = cfg.port;
            bind_addresses = [ "127.0.0.1" ];
            type = "http";
            tls = false;
            x_forwarded = true;
            resources = [{
              names = [ "client" "federation" ];
              compress = true;
            }];
          }];
          database = {
            name = "sqlite3";
            args.database = "${cfg.state-directory}/database/data.db";
          };
        };
        extras = [ "jwt" "url-preview" ];
        extraConfigFiles = [ hostSecrets.matrixOpenIdConfig.target-file ];
        configureRedisLocally = true;
      };

      nginx = {
        enable = true;
        virtualHosts = {
          "${cfg.hostname}" = {
            enableACME = true;
            forceSSL = true;
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
                ssl = false;
              }
              {
                addr = "0.0.0.0";
                port = 443;
                ssl = true;
              }
              {
                addr = "0.0.0.0";
                port = 8008;
                ssl = false;
              }
              {
                addr = "0.0.0.0";
                port = 8448;
                ssl = true;
              }
            ];
            locations."/".extraConfig = "return 404;";
            locations."/_matrix" = {
              proxyPass = "http://127.0.0.1:${toString cfg.port}";
              recommendedProxySettings = true;
              proxyWebsockets = true;
            };
            locations."/_synapse/client" = {
              proxyPass = "http://127.0.0.1:${toString cfg.port}";
              recommendedProxySettings = true;
              proxyWebsockets = true;
            };
          };
        };
      };
    };
  };
}
