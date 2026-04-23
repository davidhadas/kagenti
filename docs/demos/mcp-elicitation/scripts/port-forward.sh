#!/bin/bash

# ============================================================================
# Port Forwarding Script for MCP Elicitation Demo
# ============================================================================
# This script sets up port forwarding for all demo services
# Run this in a separate terminal window after deployment
# ============================================================================

set -e

NAMESPACE="kagenti-mcp-elicitation"
KAGENTI_NAMESPACE="kagenti-system"

echo "=============================================="
echo "Setting Up Port Forwarding"
echo "=============================================="
echo ""

# Function to start port forwarding in background
start_port_forward() {
    local name=$1
    local namespace=$2
    local service=$3
    local local_port=$4
    local remote_port=$5
    
    echo "Starting port-forward for $name..."
    kubectl port-forward -n $namespace svc/$service $local_port:$remote_port > /dev/null 2>&1 &
    local pid=$!
    echo "  PID: $pid"
    echo "  URL: http://localhost:$local_port"
    echo ""
    
    # Store PID for cleanup
    echo "$pid" >> /tmp/mcp-demo-port-forwards.pids
}

# Clean up any existing port forwards
if [ -f /tmp/mcp-demo-port-forwards.pids ]; then
    echo "Cleaning up existing port forwards..."
    while read pid; do
        kill $pid 2>/dev/null || true
    done < /tmp/mcp-demo-port-forwards.pids
    rm /tmp/mcp-demo-port-forwards.pids
    echo ""
fi

# Create new PID file
touch /tmp/mcp-demo-port-forwards.pids

# Start port forwards
echo "Starting port forwards..."
echo ""

start_port_forward "Kagenti Dashboard" "$KAGENTI_NAMESPACE" "kagenti-ui" "8080" "8080"
start_port_forward "Keycloak Admin" "keycloak" "keycloak-service" "8081" "8080"
start_port_forward "Demo Backend" "$NAMESPACE" "backend" "8187" "8187"

echo "=============================================="
echo "Port Forwarding Active"
echo "=============================================="
echo ""
echo "Access the services at:"
echo "  Kagenti Dashboard: http://localhost:8080"
echo "  Keycloak Admin:    http://localhost:8081"
echo "  Demo Backend:      http://localhost:8187"
echo ""
echo "To stop port forwarding, run:"
echo "  ${BASH_SOURCE[0]} stop"
echo ""
echo "Or manually kill the processes:"
echo "  kill \$(cat /tmp/mcp-demo-port-forwards.pids)"
echo ""

# If first argument is not "stop", wait for user interrupt
if [ "$1" != "stop" ]; then
    echo "Press Ctrl+C to stop all port forwards..."
    trap "echo ''; echo 'Stopping port forwards...'; kill \$(cat /tmp/mcp-demo-port-forwards.pids 2>/dev/null) 2>/dev/null; rm /tmp/mcp-demo-port-forwards.pids 2>/dev/null; echo 'Port forwards stopped.'; exit 0" INT
    
    # Keep script running
    while true; do
        sleep 1
    done
fi

# Made with Bob