# Copyright 2025 IBM Corp.
# Licensed under the Apache License, Version 2.0

"""
Unit tests for route utility functions.
"""

import pytest
from unittest.mock import MagicMock, patch

from kubernetes.client import ApiException


@pytest.fixture
def kubernetes_service():
    """Create a KubernetesService instance with mocked APIs."""
    with (
        patch("app.services.kubernetes.kubernetes.config.load_incluster_config"),
        patch("app.services.kubernetes.kubernetes.config.load_kube_config"),
        patch("app.services.kubernetes.kubernetes.client.ApiClient"),
        patch.dict("os.environ", {}, clear=False),
    ):
        from app.services.kubernetes import KubernetesService

        service = KubernetesService()
        service._apps_api = MagicMock()
        service._core_api = MagicMock()
        service._batch_api = MagicMock()
        return service


class TestResolveAgentUrl:
    """Test cases for resolve_agent_url()."""

    @patch("app.utils.routes.settings")
    def test_custom_port(self, mock_settings, kubernetes_service):
        """Service with non-default port returns URL with that port."""
        mock_settings.is_running_in_cluster = True
        mock_result = MagicMock()
        mock_result.to_dict.return_value = {
            "spec": {"ports": [{"port": 8082, "targetPort": 8082}]},
        }
        kubernetes_service._core_api.read_namespaced_service.return_value = mock_result

        from app.utils.routes import resolve_agent_url

        url = resolve_agent_url("my-agent", "team1", kubernetes_service)
        assert url == "http://my-agent.team1.svc.cluster.local:8082"

    @patch("app.utils.routes.settings")
    def test_default_port(self, mock_settings, kubernetes_service):
        """Service with default port 8080 returns URL with 8080."""
        mock_settings.is_running_in_cluster = True
        mock_result = MagicMock()
        mock_result.to_dict.return_value = {
            "spec": {"ports": [{"port": 8080, "targetPort": 8000}]},
        }
        kubernetes_service._core_api.read_namespaced_service.return_value = mock_result

        from app.utils.routes import resolve_agent_url

        url = resolve_agent_url("my-agent", "team1", kubernetes_service)
        assert url == "http://my-agent.team1.svc.cluster.local:8080"

    @patch("app.utils.routes.settings")
    def test_service_not_found(self, mock_settings, kubernetes_service):
        """Missing Service falls back to default port."""
        mock_settings.is_running_in_cluster = True
        kubernetes_service._core_api.read_namespaced_service.side_effect = ApiException(
            status=404, reason="Not Found"
        )

        from app.utils.routes import resolve_agent_url

        url = resolve_agent_url("my-agent", "team1", kubernetes_service)
        assert url == "http://my-agent.team1.svc.cluster.local:8080"

    @patch("app.utils.routes.settings")
    def test_service_no_ports(self, mock_settings, kubernetes_service):
        """Service with empty ports list falls back to default port."""
        mock_settings.is_running_in_cluster = True
        mock_result = MagicMock()
        mock_result.to_dict.return_value = {"spec": {"ports": []}}
        kubernetes_service._core_api.read_namespaced_service.return_value = mock_result

        from app.utils.routes import resolve_agent_url

        url = resolve_agent_url("my-agent", "team1", kubernetes_service)
        assert url == "http://my-agent.team1.svc.cluster.local:8080"

    @patch("app.utils.routes.settings")
    def test_off_cluster_custom_port(self, mock_settings, kubernetes_service):
        """Off-cluster URL uses domain name with actual Service port."""
        mock_settings.is_running_in_cluster = False
        mock_settings.domain_name = "localtest.me"
        mock_result = MagicMock()
        mock_result.to_dict.return_value = {
            "spec": {"ports": [{"port": 9090, "targetPort": 8000}]},
        }
        kubernetes_service._core_api.read_namespaced_service.return_value = mock_result

        from app.utils.routes import resolve_agent_url

        url = resolve_agent_url("my-agent", "team1", kubernetes_service)
        assert url == "http://my-agent.team1.localtest.me:9090"
