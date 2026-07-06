// fetch_jira_roadmap.mjs — pulls AP suite epics from Jira into data/roadmap.json.
//
// Reads credentials from ../../john-braithwaite-workspace/.cursor/mcp.json
// (falls back to env vars JIRA_BASE_URL, JIRA_USERNAME, JIRA_API_TOKEN).
//
// Usage:
//   node scripts/fetch_jira_roadmap.mjs \
//     --jql 'component in ("PXF - Invoices", "ELI", "IPS") AND issuetype = Epic' \
//     --out data/roadmap.json
//
// Same pattern as vendor-enablement-hub/scripts/fetch_jira_roadmap.mjs.
import fs from "node:fs";
import path from "node:path";

const MCP_CONFIG_PATH = path.resolve(
  process.env.HOME,
  "entrata-product/john-braithwaite-workspace/.cursor/mcp.json"
);

function readJiraCreds() {
  if (process.env.JIRA_BASE_URL && process.env.JIRA_USERNAME && process.env.JIRA_API_TOKEN) {
    return {
      baseUrl: process.env.JIRA_BASE_URL,
      username: process.env.JIRA_USERNAME,
      apiToken: process.env.JIRA_API_TOKEN,
    };
  }
  const cfg = JSON.parse(fs.readFileSync(MCP_CONFIG_PATH, "utf8"));
  const jira = cfg.mcpServers?.Jira;
  if (!jira) throw new Error("Jira MCP not found in mcp.json");
  const args = (jira.args || []).join(" ");
  return {
    baseUrl: args.match(/--jira-base-url=([^\s]+)/)?.[1],
    username: args.match(/--jira-username=([^\s]+)/)?.[1],
    apiToken: args.match(/--jira-api-token=([^\s]+)/)?.[1],
  };
}

function parseArgs() {
  const out = { jql: null, out: null };
  for (let i = 2; i < process.argv.length; i += 2) {
    const key = process.argv[i].replace(/^--/, "");
    out[key] = process.argv[i + 1];
  }
  if (!out.jql || !out.out) {
    console.error("Usage: fetch_jira_roadmap.mjs --jql '<JQL>' --out data/roadmap.json");
    process.exit(1);
  }
  return out;
}

async function main() {
  const args = parseArgs();
  const creds = readJiraCreds();
  const auth = "Basic " + Buffer.from(`${creds.username}:${creds.apiToken}`).toString("base64");

  const fields = ["summary", "status", "priority", "assignee", "fixVersions", "components", "duedate"];
  const epics = [];
  let nextPageToken;
  do {
    const body = {
      jql: args.jql,
      fields,
      maxResults: 100,
      nextPageToken,
    };
    const res = await fetch(`${creds.baseUrl}/rest/api/3/search/jql`, {
      method: "POST",
      headers: { Authorization: auth, "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`Jira search HTTP ${res.status}: ${await res.text()}`);
    const page = await res.json();
    for (const issue of page.issues || []) {
      epics.push({
        key: issue.key,
        summary: issue.fields.summary,
        status: issue.fields.status?.name,
        priority: issue.fields.priority?.name,
        assignee: issue.fields.assignee?.displayName,
        fixVersions: (issue.fields.fixVersions || []).map((v) => v.name),
        components: (issue.fields.components || []).map((c) => c.name),
        duedate: issue.fields.duedate,
      });
    }
    nextPageToken = page.nextPageToken;
  } while (nextPageToken);

  const payload = {
    _generated_at: new Date().toISOString(),
    _jql: args.jql,
    _count: epics.length,
    epics,
  };
  fs.mkdirSync(path.dirname(args.out), { recursive: true });
  fs.writeFileSync(args.out, JSON.stringify(payload, null, 2));
  console.log(`Wrote ${epics.length} epics to ${args.out}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
