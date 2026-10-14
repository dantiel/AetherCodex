# Mnemosyne & Aegis — The Memory Cascade

> *One crystal, many facets. Memory is not a log — it is a cascade, and the oracle drinks from it.*

## Mnemosyne — the store

Mnemosyne is the oracle's memory: a SQLite-backed palace with a single store and
many facets. Three layers, each with a different shape of remembering:

| Layer | Shape | What it holds |
|-------|-------|---------------|
| **Episodic** | `project_notes`, facet-tagged | what happened — the project's story |
| **Procedural** | `companion_skill` | how to act — distilled action skills |
| **Identitary** | `companion_state` | who each companion has become — accumulated self per glyph |

Every companion reads and writes through its **own facet**, but the store is
**single**. The owl's architecture maps and the fox's lateral paths live in the
same palace; only the facet differs.

## Aegis — the orientation

Aegis is the *sharp edge* of memory — the short-term focus that keeps context
coherent *right now*. Where Mnemosyne is the palace, Aegis is the torch.

It holds the dynamic agent state: the **summary** (current orientation), the
**tags**, the **temperature**, the **thinking depth**, and the **working
directory**. It is rewritten every turn, so the oracle does not drift across a
long session — Aegis always knows where it stands.

## The Aethernaut's Manifest

The ship is the **Argo**; the crew are the **aethernauts**. Every companion
suggestion is not a throwaway popover but an **intention** — a sailor with a
mission, signed into the ship's log.

One queue, many shapes (polymorphism, not a switch appended later):

| Kind | Glyph | Default action |
|------|-------|----------------|
| suggestion | ✨ | suggest |
| directive | 🎯 | oracle |
| recovery (Riss-Faden) | 🪡 | recover_last_intent |
| ritual | 🔮 | seal_run |
| conjuration | 🌀 | conjuration |
| insight | 💠 | remember |

**Aegis becomes Pythia's agenda** — `Mnemosyne::Aegis.agenda` reads the manifest,
so the voice's schedule *is* the oracle's orientation.

## Metempsychosis

Memory transmigrates. **Metempsychosis** moves knowledge between contexts — one
task can consult another's notes, subscribe to its orientation, or spawn a task
on a remote context over ÆtherLink. The soul moves in, not just visits.

## The facets

The companions are the facets of this one crystal — see
[The Council](companions.html) for the twelve voices that read and write through
it.
