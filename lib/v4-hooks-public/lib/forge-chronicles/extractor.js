const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

// ========== ABOUT ==========

/*

Given the latest broadcast file,
Updates the deployment history and latest data for the chain.

Note: Only TransparentUpgradeableProxy by OpenZeppelin is supported at the moment.

*/

// Note: Do not force in production.
async function extractAndSaveJson(scriptName, chainId, rpcUrl, force, broadcastDir, outDir) {
  // ========== PREPARE FILES ==========

  // Latest broadcast
  const filePath = path.join(__dirname, `../../${broadcastDir}/${scriptName}/${chainId}/run-latest.json`);
  const jsonData = JSON.parse(fs.readFileSync(filePath, "utf-8"));

  // Previously extracted data
  const recordFilePath = path.join(__dirname, `../../deployments/json/${chainId}.json`);
  let recordData;

  // Try to read previously extracted data
  try {
    recordData = JSON.parse(fs.readFileSync(recordFilePath, "utf8"));
  } catch (error) {
    // If the file doesn't exist, create a new JSON
    recordData = {
      chainId: chainId,
      latest: {},
      history: [],
    };
  }

  // Abort if commit processed
  if (recordData.history.length > 0) {
    const latestEntry = recordData.history[0];
    if (latestEntry.commitHash === jsonData.commit && !force) {
      console.error(`Commit ${jsonData.commit} already processed. Aborted.`);
      process.exit(1);
    }
  }

  // Generate Forge artifacts
  prepareArtifacts();

  // ========== UPDATE LATEST ==========

  const upgradeableTemplate = {
    implementation: "",
    address: "",
    proxy: true,
    version: "",
    proxyType: "TransparentUpgradeableProxy",
    deploymentTxn: "",
    proxyAdmin: "",
    input: {},
  };

  const nonUpgradeableTemplate = {
    address: "",
    proxy: false,
    version: "",
    deploymentTxn: "",
    input: {},
  };

  // Filter CREATE transactions
  const createTransactions = jsonData.transactions.filter((transaction) => transaction.transactionType === "CREATE");

  // For history
  const contracts = {};

  // Iterate over transactions
  for (let i = 0; i < createTransactions.length; i++) {
    const currentTransaction = createTransactions[i];
    const contractName = currentTransaction.contractName;

    // CASE: Contract name not unique
    if (contractName === null) {
      console.error("Contract name not unique. Aborted.");
      process.exit(1);
    }

    // ====== TYPE: CONTRACT NOT PROXY =====
    if (contractName !== "TransparentUpgradeableProxy") {
      // Contract exists in latest
      if (recordData.latest.hasOwnProperty(contractName)) {
        const matchedItem = recordData.latest[contractName];

        // The latest is upgradeable
        if (matchedItem.proxy) {
          // CASE: Unused implementation
          if (
            (await getImplementation(matchedItem.address, rpcUrl)).toLowerCase() !==
            currentTransaction.contractAddress.toLowerCase()
          ) {
            console.error(`${contractName} not upgraded to ${currentTransaction.contractAddress}. Aborted.`);
            process.exit(1);
          }

          // CASE: New implementation
          const upgradeableItem = {
            ...upgradeableTemplate,
            implementation: currentTransaction.contractAddress,
            proxyAdmin: matchedItem.proxyAdmin,
            address: matchedItem.address,
            proxy: true,
            version: await getVersion(matchedItem.address, rpcUrl),
            proxyType: matchedItem.proxyType,
            deploymentTxn: matchedItem.deploymentTxn,
            input: {
              constructor: matchConstructorInputs(getABI(contractName, outDir), currentTransaction.arguments),
            },
          };

          // Append it to history item
          contracts[contractName] = upgradeableItem;
          // Update latest item
          let copyOfUpgradeableItem = { ...upgradeableItem };
          delete copyOfUpgradeableItem.input;
          copyOfUpgradeableItem.timestamp = jsonData.timestamp;
          copyOfUpgradeableItem.commitHash = jsonData.commit;
          recordData.latest[contractName] = copyOfUpgradeableItem;
        } else {
          // The latest wasn't upgradeable
          // CASE: Existing non-upgradeable contract
          const nonUpgradeableItem = {
            ...nonUpgradeableTemplate,
            address: currentTransaction.contractAddress,
            version: await getVersion(currentTransaction.contractAddress, rpcUrl),
            deploymentTxn: currentTransaction.hash,
            input: {
              constructor: matchConstructorInputs(getABI(contractName, outDir), currentTransaction.arguments),
            },
          };

          // Append it to history item
          contracts[contractName] = nonUpgradeableItem;
          // Update latest item
          let copyOfNonUpgradeableItem = { ...nonUpgradeableItem };
          delete copyOfNonUpgradeableItem.input;
          copyOfNonUpgradeableItem.timestamp = jsonData.timestamp;
          copyOfNonUpgradeableItem.commitHash = jsonData.commit;
          recordData.latest[contractName] = copyOfNonUpgradeableItem;
        }
      } else {
        // Contract didn't exist in latest

        // Search for proxy in subsequent transactions
        let proxyFound = false;

        for (let j = i + 1; j < createTransactions.length; j++) {
          const nextTransaction = createTransactions[j];
          // Proxy found
          if (
            nextTransaction.contractName === "TransparentUpgradeableProxy" &&
            nextTransaction.arguments[0] === currentTransaction.contractAddress
          ) {
            // CASE: New upgradeable contract
            const upgradeableItem = {
              ...upgradeableTemplate,
              implementation: currentTransaction.contractAddress,
              proxyAdmin: nextTransaction.additionalContracts[0].address,
              address: nextTransaction.contractAddress,
              proxy: true,
              version: await getVersion(nextTransaction.contractAddress, rpcUrl),
              proxyType: nextTransaction.contractName,
              deploymentTxn: nextTransaction.hash,
              input: {
                constructor: matchConstructorInputs(getABI(contractName, outDir), currentTransaction.arguments),
                initializeData: nextTransaction.arguments[2],
              },
            };

            // Append it to history item
            contracts[contractName] = upgradeableItem;
            // Update latest item
            let copyOfUpgradeableItem = { ...upgradeableItem };
            delete copyOfUpgradeableItem.input;
            copyOfUpgradeableItem.timestamp = jsonData.timestamp;
            copyOfUpgradeableItem.commitHash = jsonData.commit;
            recordData.latest[contractName] = copyOfUpgradeableItem;

            proxyFound = true;
          }
        }
        // Didn't find proxy
        if (!proxyFound) {
          // CASE: New non-upgradeable contract
          const nonUpgradeableItem = {
            ...nonUpgradeableTemplate,
            address: currentTransaction.contractAddress,
            version: await getVersion(currentTransaction.contractAddress, rpcUrl),
            deploymentTxn: currentTransaction.hash,
            input: {
              constructor: matchConstructorInputs(getABI(contractName, outDir), currentTransaction.arguments),
            },
          };

          // Append it to history item
          contracts[contractName] = nonUpgradeableItem;
          // Update latest item
          let copyOfNonUpgradeableItem = { ...nonUpgradeableItem };
          delete copyOfNonUpgradeableItem.input;
          copyOfNonUpgradeableItem.timestamp = jsonData.timestamp;
          copyOfNonUpgradeableItem.commitHash = jsonData.commit;
          recordData.latest[contractName] = copyOfNonUpgradeableItem;
        }
      }
    } else {
      // ===== TYPE: PROXY =====
      // Check if proxy has been processed
      const proxies = Object.values(recordData.latest);
      const proxyExists = proxies.find(({ address }) => address === currentTransaction.contractAddress);

      if (!proxyExists) {
        // CASE: Unexpected proxy
        console.error(`Unexpected proxy ${currentTransaction.contractAddress}. Aborted.`);
        process.exit(1);
      }
    }
  }

  // ========== PREPEND TO HISTORY ==========

  recordData.history.unshift({
    contracts,
    timestamp: jsonData.timestamp,
    commitHash: jsonData.commit,
  });

  // ========== SAVE CHANGES ==========

  // Create file if it doesn't exist
  const directoryPath = path.dirname(recordFilePath);
  if (!fs.existsSync(directoryPath)) {
    fs.mkdirSync(directoryPath, { recursive: true });
  }

  // Write to file
  fs.writeFileSync(recordFilePath, JSON.stringify(recordData, null, 2), "utf8");

  return recordData;
}

// ========== HELPERS ==========

// IN: contract address and RPC URL
// OUT: contract version string
async function getVersion(contractAddress, rpcUrl) {
  if (rpcUrl === undefined) return undefined;
  try {
    return execSync(`cast call ${contractAddress} 'version()(string)' --rpc-url ${rpcUrl}`, {
      encoding: "utf-8",
    })
      .trim()
      .replaceAll('"', "");
  } catch (e) {
    if (!e.message.includes("execution reverted")) console.log(e); // contract does not implement version(), log otherwise
    return undefined;
  }
}

// IN: contract address and RPC URL
// OUT: implementation address
async function getImplementation(contractAddress, rpcUrl) {
  if (rpcUrl === undefined) throw new Error("No RPC URL provided, cannot verify upgrade was successful. Aborted.");
  try {
    return execSync(
      `cast storage ${contractAddress} '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc' --rpc-url ${rpcUrl} | cast parse-bytes32-address`,
      {
        encoding: "utf-8",
      },
    )
      .trim()
      .replaceAll('"', "");
  } catch (e) {
    console.log(e);
    return undefined;
  }
}

// IN: contract ABI and input values
// OUT: mappings of input names to values
function matchConstructorInputs(abi, inputData) {
  const inputMapping = {};

  const constructorFunc = abi.find((func) => func.type === "constructor");

  if (constructorFunc && inputData) {
    if (constructorFunc.inputs.length !== inputData.length) {
      console.error(`Couldn't match constructor inputs. Aborted.`);
      process.exit(1);
    }

    constructorFunc.inputs.forEach((input, index) => {
      inputMapping[input.name] = inputData[index];
    });
  }

  return inputMapping;
}

// IN: contract name
// OUT: contract ABI
function getABI(contractName, outDir) {
  const filePath = path.join(__dirname, `../../${outDir}/${contractName}.sol/${contractName}.json`);
  const fileData = fs.readFileSync(filePath, "utf8");
  const abi = JSON.parse(fileData).abi;
  return abi;
}

// Note: Ensures contract artifacts are up-to-date.
function prepareArtifacts() {
  execSync("forge build");
}

module.exports = { extractAndSaveJson };
