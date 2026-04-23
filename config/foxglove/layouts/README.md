# Foxglove Layouts

This directory contains reusable Foxglove layout presets for Link Assurance.

## Available Layouts

- `connection_health_state.json`: optimized for single-agent verification and health-state monitoring

## Recommended Usage

Use this layout for:

- quick sanity checks after launch
- focused debugging of one agent without multi-agent panel noise
- demos where readability is preferred over full fleet density

## Import Procedure

1. Open Foxglove.
2. Open the Layouts menu.
3. Select **Import from file...**.
4. Choose `config/foxglove/layouts/connection_health_state.json`.

## Topic Expectations

The layout expects these topics to be present:

- `/link_assurance/agents/agent_1/health`
- `/link_assurance/station_health`
- `/link_assurance/health_snapshot`
- `/link_assurance/link_quality_summary`
- `/diagnostics`

## Compatibility Note

If a Foxglove version rejects the layout JSON, create an equivalent layout
manually with the topic list above and re-export it using that Foxglove
version. Layout schema compatibility can vary across releases.
