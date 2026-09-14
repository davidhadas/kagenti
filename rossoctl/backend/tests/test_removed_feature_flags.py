# Copyright 2025 IBM Corp.
# Licensed under the Apache License, Version 2.0

"""The sandbox/triggers/integrations flags were removed — their routers were
never merged, so enabling one produced a UI whose every API call 404'd.
See https://github.com/rossoctl/rossoctl/issues/1764.

These tests fail if a flag is reintroduced by a bad merge.
"""

import pytest

from app.core.config import Settings
from app.routers.config import FeatureFlagsResponse

# The three flags removed by this branch — (api_name, settings_name) per flag.
REMOVED_FLAGS = (
    ("sandbox", "rossoctl_feature_flag_sandbox"),
    ("triggers", "rossoctl_feature_flag_triggers"),
    ("integrations", "rossoctl_feature_flag_integrations"),
)

# Flags that must survive — guards against an over-broad removal.
LIVE_FLAGS = ("agentSandbox", "skills", "simulatedTools", "admin")


@pytest.mark.parametrize("_api_name,settings_name", REMOVED_FLAGS)
def test_removed_flags_absent_from_settings(_api_name: str, settings_name: str):
    assert settings_name not in Settings.model_fields


@pytest.mark.parametrize("api_name,_settings_name", REMOVED_FLAGS)
def test_removed_flags_absent_from_response_model(api_name: str, _settings_name: str):
    assert api_name not in FeatureFlagsResponse.model_fields


@pytest.mark.parametrize("api_name", LIVE_FLAGS)
def test_live_flags_still_present(api_name: str):
    assert api_name in FeatureFlagsResponse.model_fields
