// playwright can be imported and its full Chrome-for-Testing build is here.
// The headless shell sends the HeadlessChrome user agent, and an origin that
// reads the client hints answers that with 403.
import fs from "node:fs";

let chromium;
try {
  ({ chromium } = await import("playwright"));
} catch {
  process.exit(1);
}
let exe;
try {
  exe = chromium.executablePath({ channel: "chromium" });
} catch {
  process.exit(1);
}
process.exit(exe && fs.existsSync(exe) ? 0 : 1);
