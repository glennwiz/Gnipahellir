# Gnipahellir Agent Play: Vision & Scope

Glenn's note, 2026-11-02, as written. Card 84 and card 92 build on it.

Vision: A game that exposes an API that AI agent CLIs — Claude Code, Codex, Copilot CLI, or anything that can run curl — can use to control a player in the game.

## 1. The idea

Gnipahellir ships with a built-in, local, documented agent API. Any tool that can make HTTP requests can observe the game world and act in it. The player's agent of choice becomes a new way to play: write a strategy, point your CLI at the game, watch it mine.

This is not an AI feature in the game. The game ships no models, calls no AI services, and works exactly as before when the API is off. The intelligence is whatever the player brings.

## Why this matters

- Agent CLIs are everywhere now. Developers already live in Claude Code, Codex and Copilot CLI. A game they can point their daily tool at is a novelty with near-zero setup cost for exactly the audience most likely to buy an indie Odin game.
- It's content. Agent runs are streamable, shareable, comparable. "My prompt beat your prompt" is a game mode nobody has to build a matchmaker for.
- First-mover window. Games are being played by agents today through screen scraping and hacks. A game designed for it is still rare.

## Non-goals

- No bundled AI, no API keys in the game, no accounts, no telemetry of agent runs.
- No cloud service. The API is local to the player's machine.
- No vendor coupling. Nothing in the game knows or cares which agent is connected.
- Not an anti-cheat problem: single-player focus; agent runs never touch human leaderboards or Steam economy features.

## 2. Design principles

- The agent is a player, not an admin. Agent actions go through the same command queue as keyboard input. Same verbs, same cooldowns, same fog of war. No debug powers, no map reveal, no spawn commands.
- Plain HTTP + JSON. No SDK required, no protocol negotiation beyond a version field. If curl can play, everything can play.
- Text-first observations. The world is described as structured text (stats, inventory, a tile grid with a legend, events). Cheap in tokens, readable by every model, trivially diffable. Screenshots are optional later.
- The world waits. Models think in seconds, not frames. A step mode pauses the simulation between actions and advances a requested number of ticks. Real-time play is a later option, not the baseline.
- Off by default, local only. Bound to 127.0.0.1, enabled explicitly in settings or via launch flag. Security posture: the API can do nothing a player with a keyboard can't.
- Deterministic when asked. A fixed-seed mode makes runs reproducible, so agents and prompts can be compared fairly.

## 3. The API

As simple as possible.

| Endpoint | Method | Purpose |
|---|---|---|
| /v1/meta | GET | Game version, protocol version, available actions and their parameters |
| /v1/state | GET | Full observation snapshot |
| /v1/state?diff=<id> | GET | Changes since snapshot <id> (token saver) |
| /v1/actions | POST | One action or an ordered batch; returns per-action results (ok / failed + reason) |
| /v1/wait | POST | Advance N ticks without acting |
| /v1/new_game | POST | Fresh run; optional seed and scenario |
| /v1/screenshot | GET | Optional, later: PNG of the current frame |

## 4. What ships in the game

- Agent server: small HTTP server on its own thread inside the binary, handing requests to the main loop through a locked queue.
- Step mode: simulation pauses awaiting input, advances on act/wait.
- Session flagging: saves and stats record "agent-assisted", keeping human leaderboards and achievements clean. Agent runs get their own board.
- Spectator overlay: last action + an optional one-line "thought" the agent sends with each act call, drawn on screen. This is what makes runs watchable.
- Run log: every observation and action appended to a JSONL file for replay, sharing and debugging.
