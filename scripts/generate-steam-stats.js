// Fetches public Steam Workshop stats for this mod and renders them as a
// self-contained SVG card for embedding in the GitHub README. No Steam API
// key is required: GetPublishedFileDetails is a public anonymous endpoint.
//
// Run with: node scripts/generate-steam-stats.js
// Regenerated daily by .github/workflows/steam-stats.yml

const fs = require("fs");
const path = require("path");

const WORKSHOP_ID = process.env.WORKSHOP_ID || "3775272983";
const MOD_TITLE = process.env.MOD_TITLE || "Brush Tool Save Fix";
const OUT_PATH = path.join(__dirname, "..", "assets", "steam-stats.svg");

async function fetchWorkshopStats(id) {
  const res = await fetch(
    "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/",
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: `itemcount=1&publishedfileids[0]=${id}`,
    }
  );
  if (!res.ok) {
    throw new Error(`Steam API request failed: ${res.status} ${res.statusText}`);
  }
  const data = await res.json();
  const details = data?.response?.publishedfiledetails?.[0];
  if (!details || details.result !== 1) {
    throw new Error(`Steam API did not return details for item ${id}`);
  }
  return {
    visitors: Number(details.views ?? 0),
    subscribers: Number(details.subscriptions ?? 0),
    favorites: Number(details.favorited ?? 0),
  };
}

function fmt(n) {
  return n.toLocaleString("en-US");
}

const ICONS = {
  eye: {
    stroke:
      '<path d="M12 5c-5 0-8.5 4-9.7 6.6a1 1 0 0 0 0 .8C3.5 15 7 19 12 19s8.5-4 9.7-6.6a1 1 0 0 0 0-.8C20.5 9 17 5 12 5Zm0 11.5a4.5 4.5 0 1 1 0-9 4.5 4.5 0 0 1 0 9Z"/><circle cx="12" cy="12" r="2.2"/>',
  },
  download: {
    stroke:
      '<path d="M12 3v10.2m0 0-3.8-3.8M12 13.2l3.8-3.8"/><path d="M5 16.5v2A2.5 2.5 0 0 0 7.5 21h9a2.5 2.5 0 0 0 2.5-2.5v-2"/>',
  },
  // Filled heart with a proper point — stroking the old closed path made a
  // flat "balloon knot" at the tip under round line joins.
  heart: {
    fill: '<path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/>',
  },
};

function iconSvg(name, x, y, size, color) {
  const icon = ICONS[name];
  if (icon.fill) {
    return `<g transform="translate(${x - size / 2},${y - size / 2}) scale(${size / 24})" fill="${color}" stroke="none">${icon.fill}</g>`;
  }
  return `<g transform="translate(${x - size / 2},${y - size / 2}) scale(${size / 24})" fill="none" stroke="${color}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">${icon.stroke}</g>`;
}

function renderCard({ visitors, subscribers, favorites }, updatedAt) {
  const width = 620;
  const height = 148;
  const columns = [
    { icon: "eye", value: visitors, label: "UNIQUE VISITORS" },
    { icon: "download", value: subscribers, label: "SUBSCRIBERS" },
    { icon: "heart", value: favorites, label: "FAVORITES" },
  ];
  const colWidth = width / columns.length;

  const bgLight = "#f6f8fa";
  const bgDark = "#0d1420";
  const cardBorderLight = "#d0d7de";
  const cardBorderDark = "#30485f";
  const headingLight = "#57606a";
  const headingDark = "#66c0f4";
  const numberLight = "#1b1f24";
  const numberDark = "#e8f1f8";
  const labelLight = "#6e7781";
  const labelDark = "#8f98a0";
  const dividerLight = "#d8dee4";
  const dividerDark = "#1f2f3f";
  const accent = "#66c0f4";

  const columnGroups = columns
    .map((col, i) => {
      const cx = colWidth * i + colWidth / 2;
      const divider =
        i > 0
          ? `<line x1="${colWidth * i}" y1="34" x2="${colWidth * i}" y2="${height - 20}" class="divider" />`
          : "";
      return `
      ${divider}
      ${iconSvg(col.icon, cx, 62, 24, accent)}
      <text x="${cx}" y="103" text-anchor="middle" class="value">${fmt(col.value)}</text>
      <text x="${cx}" y="126" text-anchor="middle" class="label">${col.label}</text>`;
    })
    .join("\n");

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="Steam Workshop stats">
  <title>${MOD_TITLE} — Steam Workshop stats</title>
  <style>
    .card { fill: ${bgLight}; stroke: ${cardBorderLight}; }
    .heading { fill: ${headingLight}; }
    .value { fill: ${numberLight}; }
    .label { fill: ${labelLight}; }
    .divider { stroke: ${dividerLight}; }
    .updated { fill: ${labelLight}; }
    @media (prefers-color-scheme: dark) {
      .card { fill: ${bgDark}; stroke: ${cardBorderDark}; }
      .heading { fill: ${headingDark}; }
      .value { fill: ${numberDark}; }
      .label { fill: ${labelDark}; }
      .divider { stroke: ${dividerDark}; }
      .updated { fill: ${labelDark}; }
    }
    text { font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
    .heading { font-size: 13px; font-weight: 700; letter-spacing: 1px; }
    .value { font-size: 30px; font-weight: 800; }
    .label { font-size: 10.5px; font-weight: 600; letter-spacing: 0.6px; }
    .updated { font-size: 10px; }
  </style>
  <rect x="0.5" y="0.5" width="${width - 1}" height="${height - 1}" rx="10" class="card" stroke-width="1"/>
  <text x="20" y="26" class="heading">STEAM WORKSHOP STATS</text>
  <text x="${width - 20}" y="26" text-anchor="end" class="updated">updated ${updatedAt}</text>
  ${columnGroups}
</svg>
`;
}

async function main() {
  const stats = await fetchWorkshopStats(WORKSHOP_ID);
  const updatedAt = new Date().toISOString().slice(0, 10);
  const svg = renderCard(stats, updatedAt);
  fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
  fs.writeFileSync(OUT_PATH, svg, "utf8");
  console.log(`Wrote ${OUT_PATH}`);
  console.log(stats);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
