import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { transformWithEsbuild } from "vite";

const sourceRoot = resolve("src/assets/note-skins");
const targetRoot = resolve("dist/assets/note-skins");
await mkdir(targetRoot, { recursive: true });
// Keep static new URL expressions visible to the consuming asset bundler.
const { code } = await transformWithEsbuild(
  await readFile(resolve("src/assets/noteTextures.ts"), "utf8"),
  "noteTextures.ts",
  { sourcemap: false },
);
await writeFile(resolve("dist/assets/noteTextures.js"), code);
for (const skin of ["skin001", "skin002", "skin003"]) {
  await copyFile(resolve(sourceRoot, `${skin}.png`), resolve(targetRoot, `${skin}.png`));
}
