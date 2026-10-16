import { readFile, writeFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const profile = JSON.parse(await readFile(new URL("src/assets/chart-ui-profile.json", root), "utf8"));
await writeFile(
  new URL("dart/lib/chart_ui_profile.dart", root),
  `// Generated from src/assets/chart-ui-profile.json by the package build.
abstract final class OurNotesChartUiProfile {
  static const List<int> guidelineCounts = [${profile.guidelineCounts.join(", ")}];
  static const int guidelineCountDefault = ${profile.guidelineCountDefault};
}
`,
);
