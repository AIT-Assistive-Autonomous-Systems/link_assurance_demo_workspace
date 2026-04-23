# Demo Scenarios (Workspace)

Operational scenario reference for the demo workspace scripts.

## Scope

This document describes wrapper-script driven validation in this workspace.
For package-native direct commands, see
`src/link_assurance/docs/scenarios.md`.

## Safety Notes

- network fault scripts default to loopback (`lo`)
- set `LINK_ASSURANCE_TC_IFACE=<iface>` to target another interface
- targeting primary default-route interface requires
  `LINK_ASSURANCE_ALLOW_PRIMARY_IFACE=1`

## Baseline Startup

```bash
./scripts/run_demo_start.sh --agents 1
```

Split baseline alternative (station and agents started separately):

```bash
./scripts/start_station_only.sh --station-id station --agent-ids agent_1
./scripts/start_agent_only.sh --node-id agent_1 --station-id station
```

Quick checks:

```bash
ros2 topic echo /link_assurance/agents/agent_1/health --once --full-length
ros2 topic echo /link_assurance/station_health --once --full-length
ros2 topic echo /link_assurance/link_quality_summary --once --full-length
```

Expected baseline:

- continuous health publication from station and agent
- `external_link_state = CONNECTED`
- station health reports `station_service_state = OK`

## Scenario Matrix

### Network latency/jitter

```bash
./scripts/run_inject_network.sh --profile latency
```

Expected:

- RTT/jitter increase
- `external_link_state` may transition to `DEGRADED`

### Transport disconnect

```bash
./scripts/run_inject_disconnect.sh
```

Expected:

- missed probe counters increase
- `external_link_state` transitions toward `LOST`
- diagnostics and health counters reflect outage handling

### Station service failure

```bash
./scripts/run_inject_station_services.sh
```

Expected:

- `station_service_state = FAILED`
- station operational fallback activation

## Recovery Expectation

When timed injections end or scripts are interrupted, system should recover to:

- `external_link_state = CONNECTED`
- station `station_service_state = OK` (agent remains `NOT_CONFIGURED`)

## Automated Campaign Execution

```bash
./scripts/run_campaign_validation.sh --topologies 1,2 --attempt-label full
```

Useful options:

- `--scenarios latency,outage` to run a subset
- `--injection-duration 20` to extend disturbance windows
- `--continue-on-fail` to finish the matrix after a failure

Evidence interpretation for outage/disconnect:

- primary LOST signal: `external_link_state: 2` in
  `/link_assurance/station_health`
- secondary corroboration: `lost_count` in
  `/link_assurance/link_quality_summary`
- do not require `lost_count > 0` as a strict gate when station health already
  reports LOST

## Split Container Targeted Injection

Use this flow to emulate per-agent network faults without impacting all agents.

Start split containers:

```bash
./scripts/docker_split_demo_up.sh --agent-ids agent_1,agent_2 --build
```

Inject on one agent only:

```bash
./scripts/docker_inject_network.sh --target agent_2 --profile bufferbloat --duration 20
```

Expected:

- degraded/lost transitions are observed primarily for `agent_2`
- non-targeted agents remain near baseline behavior
- fleet summary reflects mixed-health state during injection window

Teardown:

```bash
./scripts/docker_split_demo_down.sh
```

## BT Showcase (Workspace Script)

Run demo stack with BT showcase enabled:

```bash
./scripts/run_demo_start.sh --agents 1 --with-bt
```

Expected:

- BT transitions are logged by `bt_showcase_node`
- JSON status is published on `/bt_showcase/status`

Per-agent split variant:

```bash
./scripts/start_agent_only.sh --node-id agent_1 --station-id station --with-bt
```

Expected per-agent status topic:

- `/link_assurance/agents/agent_1/bt_showcase/status`
