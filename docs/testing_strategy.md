# Demo Validation Strategy (Workspace)

Validation strategy for this workspace orchestration and script layer.

## Scope

This document covers:

- demo startup wrappers
- fault-injection wrappers
- campaign runner behavior and evidence artifacts

For package-level unit/integration tests, see
`src/link_assurance/docs/testing_strategy.md`.

## Standard Workspace Checks

```bash
./scripts/build.sh
source /opt/ros/kilted/setup.bash
source install/setup.bash
colcon test --event-handlers console_direct+
colcon test-result --all --verbose
```

## Script-Level Runtime Validation

Run selective injections while demo is active:

```bash
./scripts/run_demo_start.sh --agents 1 --with-bt
./scripts/run_inject_network.sh --profile wifi_congested --duration 20
./scripts/run_inject_disconnect.sh
./scripts/run_inject_station_services.sh
```

Check key topics:

- `/link_assurance/station_health`
- `/link_assurance/agents/<agent_id>/health`
- `/link_assurance/health_snapshot`
- `/link_assurance/link_quality_summary`

## Split Deployment Validation

Validate split station/agent mode (terminals or machines):

```bash
./scripts/start_station_only.sh --station-id station --agent-ids agent_1,agent_2
./scripts/start_agent_only.sh --node-id agent_1 --station-id station
./scripts/start_agent_only.sh --node-id agent_2 --station-id station
```

Validate local multi-container emulation:

```bash
./scripts/docker_split_demo_up.sh --agent-ids agent_1,agent_2 --build
./scripts/docker_inject_network.sh --target agent_2 --profile bufferbloat --duration 20
./scripts/docker_inject_network.sh --target station --profile outage --duration 10
./scripts/docker_split_demo_down.sh
```

Expected split-mode outcomes:

- station tracks all configured agents from independent processes/containers
- targeted agent-network injection primarily affects the selected agent path
- non-targeted agents remain connected unless shared infrastructure is impaired

## Campaign Validation

Run repeatable matrix validation:

```bash
./scripts/run_campaign_validation.sh --topologies 1,2 --attempt-label full
```

Supported campaign scenarios:

- `latency`
- `wifi_congested`
- `burst_loss`
- `reordering`
- `bufferbloat`
- `outage`
- `disconnect`
- `station_services`

Artifacts are written under `log/campaign_<timestamp>/` and include:

- `timeline.log` (ordered run lifecycle events)
- `results.tsv` (per-scenario detection/recovery verdicts)
- per-run folders with logs and snapshots

Detection guidance for outage/disconnect scenarios:

- authoritative LOST signal: `station_health.external_link_state = LOST`
- `link_quality_summary.lost_count` is useful corroboration but not a strict
  sole gate

## Acceptance Criteria

A workspace validation run is accepted when:

1. build and package tests pass
2. scenario injections trigger expected transitions
3. recovery returns to expected healthy states
4. campaign matrix produces passing verdicts for required topologies
5. split-mode startup and targeted per-agent injection behave as expected
