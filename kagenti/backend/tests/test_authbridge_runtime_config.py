# Copyright 2025 IBM Corp.
# Licensed under the Apache License, Version 2.0

"""Tests for _build_authbridge_runtime_yaml helper."""

import yaml


def test_build_authbridge_runtime_yaml_client_secret():
    """Default (non-SPIRE) config uses client-secret identity."""
    from app.routers.agents import _build_authbridge_runtime_yaml

    result = _build_authbridge_runtime_yaml(
        keycloak_url="http://keycloak:8080",
        realm="kagenti",
        issuer="http://keycloak.example.com/realms/kagenti",
        spire_enabled=False,
    )
    cfg = yaml.safe_load(result)

    assert cfg["mode"] == "envoy-sidecar"
    assert cfg["inbound"]["issuer"] == "http://keycloak.example.com/realms/kagenti"
    assert cfg["outbound"]["keycloak_url"] == "http://keycloak:8080"
    assert cfg["outbound"]["keycloak_realm"] == "kagenti"
    assert cfg["outbound"]["default_policy"] == "passthrough"
    assert cfg["identity"]["type"] == "client-secret"
    assert cfg["identity"]["client_id_file"] == "/shared/client-id.txt"
    assert cfg["identity"]["client_secret_file"] == "/shared/client-secret.txt"
    assert "jwt_svid_path" not in cfg["identity"]
    assert len(cfg["bypass"]["inbound_paths"]) == 4


def test_build_authbridge_runtime_yaml_spire_enabled():
    """SPIRE-enabled config maps to spiffe identity with jwt_svid_path."""
    from app.routers.agents import _build_authbridge_runtime_yaml

    result = _build_authbridge_runtime_yaml(
        keycloak_url="http://keycloak:8080",
        realm="kagenti",
        issuer="http://keycloak.example.com/realms/kagenti",
        spire_enabled=True,
    )
    cfg = yaml.safe_load(result)

    assert cfg["identity"]["type"] == "spiffe"
    assert cfg["identity"]["jwt_svid_path"] == "/opt/jwt_svid.token"
    assert cfg["identity"]["client_id_file"] == "/shared/client-id.txt"
