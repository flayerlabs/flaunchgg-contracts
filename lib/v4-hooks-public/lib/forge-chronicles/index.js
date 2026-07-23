const { readFileSync, existsSync } = require("fs");
const path = require("path");
const { extractAndSaveJson } = require("./extractor.js");
const { generateAndSaveMarkdown } = require("./generateMarkdown.js");
/**
 * @description Extracts contract deployment data from run-latest.json (foundry broadcast output) and writes to deployments/json/{chainId}.json & deployments/{chainId}.md
 * @usage node index.js {chainId} [scriptName = "Deploy.s.sol"] [--skip-json | -s]
 * @dev
 *  currently only supports TransparentUpgradeableProxy pattern
 *  foundry (https://getfoundry.sh) required
 */
async function main() {
  let [chainId, scriptName, skipJsonFlag, rpcUrl, force, broadcastDir, outDir] = validateAndExtractInputs();
  if (rpcUrl === undefined) {
    console.warn("\u{26A0} No rpc url provided, skipping version fetching");
  }
  let json;
  if (!skipJsonFlag) json = await extractAndSaveJson(scriptName, chainId, rpcUrl, force, broadcastDir, outDir);
  else {
    console.log("Skipping json extraction, using existing json file");
    const recordFilePath = path.join(__dirname, `../../deployments/json/${chainId}.json`);
    if (!existsSync(recordFilePath)) throw new Error(`error: ${recordFilePath} does not exist`);
    json = JSON.parse(readFileSync(recordFilePath, "utf-8"));
  }
  generateAndSaveMarkdown(json);
}

function validateAndExtractInputs() {
  const scriptName = process.argv[2];

  if (scriptName === undefined || scriptName === "-h" || scriptName === "--help") {
    printHelp();
    process.exit(0);
  } else if (scriptName === "-v" || scriptName === "--version") {
    console.log(JSON.parse(readFileSync("lib/forge-chronicles/package.json", "utf8")).version);
    process.exit(0);
  }

  const args = process.argv.slice(3);
  let forceFlag = false;
  let skipJsonFlag = false;
  let chainId = 31337;
  let rpcUrl = process.env.RPC_URL;
  let broadcastDir = "broadcast";
  let outDir = "out";
  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--force":
      case "-f":
        forceFlag = true;
        break;
      case "--skip-json":
      case "-s":
        skipJsonFlag = true;
        break;
      case "-c":
      case "--chain-id":
        // Check if there's another argument after --chain-id and the argument is not another command
        if (i + 1 < args.length && args[i + 1].charAt(0) !== "-") {
          chainId = args[i + 1];
          i++; // Skip the next argument
          break;
        } else {
          console.error("Error: --chain-id flag requires the chain id of the network where the script was executed");
          process.exit(1);
        }
      case "-r":
      case "--rpc-url":
        // Check if there's another argument after --rpc-url and the argument is not another command
        if (i + 1 < args.length && args[i + 1].charAt(0) !== "-") {
          rpcUrl = args[i + 1];
          i++; // Skip the next argument
          break;
        } else {
          console.error("Error: --rpc-url flag requires an rpc url");
          process.exit(1);
        }
      case "-b":
      case "--broadcast-dir":
        // Check if there's another argument after --broadcast-dir and the argument is not another command
        if (i + 1 < args.length && args[i + 1].charAt(0) !== "-") {
          broadcastDir = args[i + 1];
          i++; // Skip the next argument
          break;
        } else {
          console.error("Error: --broadcast-dir flag requires a directory path");
          process.exit(1);
        }
      case "-o":
      case "--out-dir":
        // Check if there's another argument after --output-dir and the argument is not another command
        if (i + 1 < args.length && args[i + 1].charAt(0) !== "-") {
          outDir = args[i + 1];
          i++; // Skip the next argument
          break;
        } else {
          console.error("Error: --out-dir flag requires a directory path");
          process.exit(1);
        }
      default:
        printHelp();
        process.exit(1);
    }
  }

  return [chainId, scriptName, skipJsonFlag, rpcUrl, forceFlag, broadcastDir, outDir];
}

const printHelp = () => {
  console.log(
    "\nUsage: node lib/forge-chronicles <scriptName> [-c chain-id] [-r rpc-url] [-s skip-json] [-b broadcast-dir] [-o out-dir]\n\nCommands:\n  -c, --chain-id\tChain id of the network where the script was executed (default: 31337)\n  -r, --rpc-url\t\tRPC url used to fetch the version of the contract or verify an upgrade (default: $RPC_URL). If no rpc url is provided, version fetching is skipped.\n  -s, --skip-json\tSkips the json generation and creates the markdown file using an existing json file\n  -b, --broadcast-dir\tDirectory where the broadcast files are stored (default: broadcast)\n  -o, --out-dir\t\tDirectory where the foundry output files are stored (default: out)\n\nOptions:\n  -h, --help\t\tPrint help\n  -v, --version\t\tPrint version\n\nDocumentation can be found at https://github.com/0xPolygon/forge-chronicles",
  );
};

main();
