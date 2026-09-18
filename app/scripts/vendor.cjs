const { copyFileSync, mkdirSync } = require("node:fs");
const { join } = require("node:path");

// Runtime assets are bundled so local simulations never require a CDN.
const root = join(__dirname, "..");
const target = join(root, "public", "vendor");
mkdirSync(target, { recursive: true });
const files = [
  ["chart.js/dist/chart.umd.min.js", "chart.umd.min.js"],
  ["chart.js/LICENSE.md", "LICENSE-chartjs.md"],
  ["lucide/dist/umd/lucide.min.js", "lucide.min.js"],
  ["lucide/LICENSE", "LICENSE-lucide"],
  ["@fontsource/inter/LICENSE", "LICENSE-inter"],
];
for (const weight of [400, 600]) {
  files.push([
    "@fontsource/inter/files/inter-latin-" + weight + "-normal.woff2",
    "inter-latin-" + weight + "-normal.woff2",
  ]);
}
for (const [source, destination] of files) {
  copyFileSync(join(root, "node_modules", source), join(target, destination));
}
console.log("Bundled " + files.length + " local assets and licenses.");
