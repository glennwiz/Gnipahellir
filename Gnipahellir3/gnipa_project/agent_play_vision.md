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
