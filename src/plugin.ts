import { defineCassiopeiaPlugin, defineCassiopeiaService } from "@haneoka/cassiopeia/plugin";
import { buildChart } from "./core/chart";
import { parseScore } from "./core/parser";
import { RenderFrameBuilder } from "./adapter/renderFrame";
import { createOurNotesAssetManifest } from "./assets/manifest";
import { HapticFeedback } from "./presentation/HapticFeedback";

export const OUR_NOTES_RULES = defineCassiopeiaService<{
  parse: (input: unknown) => ReturnType<typeof buildChart>;
  createFrameBuilder: (
    chart: ConstructorParameters<typeof RenderFrameBuilder>[0],
    options?: ConstructorParameters<typeof RenderFrameBuilder>[1],
  ) => RenderFrameBuilder;
  createAssets: typeof createOurNotesAssetManifest;
  createHaptics: (...args: ConstructorParameters<typeof HapticFeedback>) => HapticFeedback;
}>("our-notes.rules.v1");
export function createOurNotesPlugin() {
  return defineCassiopeiaPlugin({
    manifest: {
      id: "cassiopeia.our-notes",
      version: "0.1.0",
      apiVersion: 1,
      requires: ["cassiopeia.kernel"],
      provides: [OUR_NOTES_RULES.id],
    },
    setup(context) {
      context.provide(OUR_NOTES_RULES, {
        parse: (input) => buildChart(parseScore(input)),
        createFrameBuilder: (chart, options) => new RenderFrameBuilder(chart, options),
        createAssets: createOurNotesAssetManifest,
        createHaptics: (...args) => new HapticFeedback(...args),
      });
    },
  });
}
