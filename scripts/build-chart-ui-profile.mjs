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

const haptics = JSON.parse(await readFile(new URL("src/assets/haptic-feedback-profile.json", root), "utf8"));
const recipes = [0];
for (const row of haptics.haptics._allData) {
  if (row._setID === haptics.setId) recipes[row._liveHapticType] = row._recipeID;
}
const noFeedback = haptics.recipes._allData.find((row) => row._iosPlayType === 0 && row._androidPlayType === 0);
await writeFile(
  new URL("dart/lib/src/haptic_feedback_profile.dart", root),
  `// Generated from src/assets/haptic-feedback-profile.json by the package build.
abstract final class OurNotesHapticFeedbackProfile {
  static const int minimumIntervalMicros = ${haptics.minimumIntervalMicros};
  static const int maximumPendingRequests = ${haptics.maximumPendingRequests};
  static const int noneRecipeId = ${noFeedback._id};
  static const List<int> recipeByType = [
    ${recipes.join(",\n    ")},
  ];
  static const List<Map<String, Object>> recipes = ${JSON.stringify(haptics.recipes._allData)};
}
`,
);
