# Split Deployment Guide (Workspace)

This guide adds an advanced deployment mode while keeping
`./scripts/run_demo_start.sh` as the default quick-start.

## Goal

Run station-side services and agent-side services independently so the same
workflow can be used for:

- separate terminals on one machine
- separate containers on one host
- separate machines on a network

## Runtime Contract

All participants must agree on:

- `RMW_IMPLEMENTATION` (recommended: `rmw_zenoh_cpp`)
- `ROS_DOMAIN_ID` (same integer across station + all agents)
- `ROS_LOCALHOST_ONLY=0` for multi-host/container discovery
- matching IDs:
  - station `--agent-ids` contains every agent `--node-id`
  - agents use the same `--station-id` that station uses

## Split Start Scripts

### Station side

```bash
./scripts/start_station_only.sh --station-id station --agent-ids agent_1,agent_2
```

By default this starts:

- `link_assurance_station_node`
- `link_assurance_summary`

Disable visualization on station side when needed:

```bash
./scripts/start_station_only.sh --station-id station --agent-ids agent_1,agent_2 --no-visualization
```

### Agent side

Start one script instance per agent:

```bash
./scripts/start_agent_only.sh --node-id agent_1 --station-id station
./scripts/start_agent_only.sh --node-id agent_2 --station-id station
```

## Single-Machine Split Demo (Separate Terminals)

1. Terminal A:

```bash
./scripts/start_station_only.sh --station-id station --agent-ids agent_1,agent_2
```

2. Terminal B:

```bash
./scripts/start_agent_only.sh --node-id agent_1 --station-id station
```

3. Terminal C:

```bash
./scripts/start_agent_only.sh --node-id agent_2 --station-id station
```

4. Verify:

```bash
ros2 topic echo /link_assurance/station_health --once --full-length
ros2 topic echo /link_assurance/agents/agent_1/health --once --full-length
ros2 topic echo /link_assurance/agents/agent_2/health --once --full-length
```

## Local Multi-Container Emulation

Prerequisites:

- Docker daemon reachable from this shell (`docker ps` works)
- if using VS Code devcontainer, rebuild/reopen after Docker tooling changes so
  the docker socket mount from `.devcontainer/devcontainer.json` is active

### Start split containers

```bash
./scripts/docker_split_demo_up.sh --agent-ids agent_1,agent_2
```

This creates:

- one station container (default name: `la_station`)
- one container per agent (default names: `la_agent_<agent_id>`)
- one router container in Zenoh mode (default name: `la_zenoh_router`)

It also starts Foxglove bridge in the station container by default and exposes
`ws://localhost:8765`.

Optional flags:

- `--no-foxglove` to disable auto-start
- `--foxglove-port <port>` to change published websocket port

If the requested Foxglove port is already occupied, startup automatically
retries with the next available port and logs the final websocket URL.

If needed, start/restart bridge manually:

```bash
./scripts/docker_start_foxglove_bridge.sh --station-name la_station --port 8765
```

### Target one agent network path

```bash
./scripts/docker_inject_network.sh --target agent_2 --profile bufferbloat --duration 20
./scripts/docker_inject_network.sh --target station --profile outage --duration 10
```

### Teardown

```bash
./scripts/docker_split_demo_down.sh
```

## Multi-Machine Notes

For real multi-host runs:

1. Deploy the same workspace and build outputs on each host.
2. Start station script on station host.
3. Start one agent script per agent host.
4. Ensure firewall/network allows ROS/Zenoh discovery and traffic.
5. Keep `ROS_LOCALHOST_ONLY=0` on all hosts.

Example with explicit runtime env:

```bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
export ROS_DOMAIN_ID=42
export ROS_LOCALHOST_ONLY=0
```

## Troubleshooting

- If station does not show one agent, confirm station `--agent-ids` includes
  that exact agent `--node-id`.
- If no cross-process discovery happens, verify all participants have matching
  `ROS_DOMAIN_ID` and `RMW_IMPLEMENTATION`.
- For container injection failures, ensure containers run with `NET_ADMIN` and
  target interface `eth0` exists in the target container.
- If scripts report missing overlay, run `./scripts/build.sh` first.
