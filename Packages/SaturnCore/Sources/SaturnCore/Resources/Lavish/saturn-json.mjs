import { spawn } from "node:child_process";
import { decode } from "@toon-format/toon";

const [cli, ...args] = process.argv.slice(2);
const child = spawn(process.execPath, [cli, ...args], { stdio: ["ignore", "pipe", "inherit"], env: process.env });
const chunks = [];
child.stdout.on("data", (chunk) => chunks.push(chunk));

for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(signal, () => child.kill(signal));
}

child.on("close", (code, signal) => {
  const text = Buffer.concat(chunks).toString("utf8").trim();
  let output;
  try {
    output = JSON.stringify(decode(text));
  } catch {
    output = JSON.stringify({ raw: text });
  }
  process.stdout.write(output + "\n");
  process.exit(code ?? (signal ? 143 : 1));
});
