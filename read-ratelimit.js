const fs = require('fs');
const path = require('path');
const os = require('os');

const projectsDir = path.join(os.homedir(), '.claude', 'projects');
const files = [];
function walk(dir) {
  for (const f of fs.readdirSync(dir)) {
    const full = path.join(dir, f);
    if (fs.statSync(full).isDirectory()) walk(full);
    else if (f.endsWith('.jsonl')) files.push(full);
  }
}
walk(projectsDir);

// Find the most recent entry with rateLimitInfo
let latest = null;
for (const file of files) {
  const lines = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
  for (const line of lines) {
    if (!line.includes('rateLimitInfo')) continue;
    try {
      const obj = JSON.parse(line);
      if (obj.rateLimitInfo && obj.timestamp) {
        if (!latest || obj.timestamp > latest.timestamp) {
          latest = { rateLimitInfo: obj.rateLimitInfo, timestamp: obj.timestamp };
        }
      }
    } catch {}
  }
}

if (latest) {
  console.log(JSON.stringify(latest, null, 2));
} else {
  console.log('{}');
}
