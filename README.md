# Cassiopeia Our Notes plugin

Owns the original game's SS parsing/normalization, render-frame generation,
extracted skin/effect metadata, title presentation and haptic selection.
It contains no renderer, browser audio implementation, Vue or Sonolus SDK.

```ts
import { createOurNotesPlugin, OUR_NOTES_RULES } from '@haneoka/cassiopeia-plugin-our-notes';
// Install after createKernelPlugin(), then:
const rules = runtime.require(OUR_NOTES_RULES);
const chart = rules.parse(scorePayload);
const frames = rules.createFrameBuilder(chart);
const assets = rules.createAssets(media, { asset: resolveAsset, runtime: resolveRuntime });
```

The website and Sonolus adapter use this same normalization. Game media is
provided by the host through resolvers; no website endpoint is required.
Vibration cues preserve original feedback IDs, and hosts own device scheduling.

Build within the locked website workspace with
`pnpm --filter @haneoka/cassiopeia-plugin-our-notes build`. Local unpublished
peers are resolved by that workspace; published packages use the declared peer
version ranges. License: MPL-2.0. Game assets retain their own terms.
