#!/usr/bin/env node
// Build and distribute only the WA Wubi iOS app. "check" never uploads.
import { randomBytes, sign, X509Certificate } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const appStore = path.join(root, "Mobile/AppStore");
const buildRoot = path.resolve(process.env.WAWUBI_IOS_BUILD_DIR ?? path.join(os.homedir(), "dev/build/wa-wubi/ios-release"));
const configPath = path.join(os.homedir(), ".apple.json");
const bundleID = "top.fuluwa.inputmethod.Wubi86.ios";
const groupID = "group.top.fuluwa.inputmethod.Wubi86";
const cloudID = "iCloud.top.fuluwa.inputmethod.Wubi86";
const targets = [
  { id: bundleID, slot: "iosBase64", title: "WA Wubi iOS", cloud: true },
  { id: bundleID + ".keyboard", slot: "iosKeyboardBase64", title: "WA Wubi iOS Keyboard", cloud: false }
];

function run(command, args, options = {}) {
  return execFileSync(command, args, { cwd: root, stdio: "inherit", ...options });
}

function capture(command, args, input) {
  return run(command, args, { input, encoding: "utf8", maxBuffer: 16 * 1024 * 1024,
    stdio: [input ? "pipe" : "ignore", "pipe", "ignore"] });
}

function read(relativePath) {
  return fs.readFileSync(path.join(appStore, relativePath), "utf8").trim();
}

function validateMaterials() {
  const limits = { name: 30, subtitle: 30, promotional_text: 170, description: 4000, keywords: 100 };
  for (const [field, limit] of Object.entries(limits)) {
    const value = read("Metadata/zh-Hans/" + field + ".txt");
    if (!value || (field === "keywords" ? Buffer.byteLength(value) : value.length) > limit) {
      throw new Error("Invalid App Store metadata: " + field);
    }
  }
  for (const field of ["support_url", "marketing_url", "privacy_url"]) {
    if (new URL(read("Metadata/zh-Hans/" + field + ".txt")).protocol !== "https:") throw new Error("Expected HTTPS for " + field);
  }
  const expected = { iphone17: "1206x2622", "iphone-duo-inner": "2853x2007", ipad13: "2064x2752" };
  const source = path.join(appStore, "Screenshots");
  const output = path.join(appStore, "Upload/zh-Hans");
  const filenames = fs.readdirSync(source).filter(name => name.endsWith(".jpg")).sort();
  const posters = fs.readdirSync(output).filter(name => name.endsWith(".jpg")).sort();
  if (!filenames.length || filenames.join() !== posters.join()) throw new Error("Each source screenshot must have one upload poster.");
  const groups = new Set();
  for (const name of posters) {
    const device = Object.keys(expected).find(key => name.startsWith(key + "-"));
    const info = capture("sips", ["-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", path.join(output, name)]);
    const width = info.match(/pixelWidth: (\d+)/)?.[1];
    const height = info.match(/pixelHeight: (\d+)/)?.[1];
    if (!device || `${width}x${height}` !== expected[device] || !info.includes("hasAlpha: no")) {
      throw new Error("Unexpected poster dimensions or alpha: " + name);
    }
    groups.add(device);
  }
  if (groups.size !== Object.keys(expected).length) throw new Error("Missing iPhone, iPhone Duo or iPad poster group.");
  console.log(`Validated ${posters.length} App Store posters and Simplified Chinese metadata.`);
}

function loadCredentials() {
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const common = config.common;
  const key = common?.appStoreConnect;
  const distribution = common?.certificates?.appleDistribution;
  if (!common?.teamId || !key?.keyId || !key.issuerId || !key.privateKeyBase64) {
    throw new Error("Apple team and App Store Connect credentials are missing in common.");
  }
  return { config, team: common.teamId, key, distribution };
}

function ascClient(key) {
  return async function asc(resource, filters = {}, create) {
    let url = new URL(resource, "https://api.appstoreconnect.apple.com/v1/");
    if (url.origin !== "https://api.appstoreconnect.apple.com") throw new Error("Unexpected App Store Connect URL");
    for (const [name, value] of Object.entries(filters)) url.searchParams.set(name, value);
    const rows = [];
    do {
      const now = Math.floor(Date.now() / 1000);
      const base64 = value => Buffer.from(JSON.stringify(value)).toString("base64url");
      const message = base64({ alg: "ES256", kid: key.keyId, typ: "JWT" }) + "." +
        base64({ iss: key.issuerId, iat: now, exp: now + 600, aud: "appstoreconnect-v1" });
      const signature = sign("sha256", Buffer.from(message), { key: Buffer.from(key.privateKeyBase64, "base64"),
        dsaEncoding: "ieee-p1363" }).toString("base64url");
      const response = await fetch(url, { method: create ? "POST" : "GET",
        headers: { Authorization: "Bearer " + message + "." + signature, "Content-Type": "application/json" },
        body: create ? JSON.stringify(create) : undefined, signal: AbortSignal.timeout(25000) });
      const result = response.status === 204 ? {} : await response.json();
      if (!response.ok) throw new Error(`Apple ${url.pathname} HTTP ${response.status}: ${result.errors?.map(error => error.code).join(", ") ?? ""}`);
      if (!Array.isArray(result.data)) return result.data;
      rows.push(...result.data);
      url = result.links?.next ? new URL(result.links.next) : null;
      if (url && url.origin !== "https://api.appstoreconnect.apple.com") throw new Error("Unexpected Apple pagination URL");
    } while (url);
    return rows;
  };
}

const platform = { "filter[platform]": "IOS", limit: 200 };
const parts = version => version.split(".").map(Number);
function compare(a, b) {
  const x = parts(a);
  const y = parts(b);
  return (x[0] - y[0]) || ((x[1] ?? 0) - (y[1] ?? 0)) || ((x[2] ?? 0) - (y[2] ?? 0));
}

async function chooseVersion(asc, appID, requestedVersion, lane) {
  const editing = new Set(["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"]);
  const [versions, trains] = await Promise.all([
    asc(`apps/${appID}/appStoreVersions`, platform), asc("preReleaseVersions", { ...platform, "filter[app]": appID })
  ]);
  const newest = versions.sort((a, b) => compare(b.attributes.versionString, a.attributes.versionString))[0]?.attributes;
  let version = requestedVersion;
  if (!version && newest && editing.has(newest.appVersionState ?? newest.appStoreState)) version = newest.versionString;
  if (!version && newest) {
    const [major, minor = 0, patch = 0] = parts(newest.versionString);
    version = `${major}.${minor}.${patch + 1}`;
  }
  version ??= "0.1.0";
  if (!requestedVersion && lane === "testflight") {
    const beta = trains.map(train => train.attributes.version).sort(compare).at(-1);
    if (beta && compare(beta, version) > 0) version = beta;
  }
  if (!/^\d+\.\d+(\.\d+)?$/.test(version)) throw new Error("Invalid iOS version.");
  const train = trains.find(item => item.attributes.version === version);
  const builds = train ? await asc("builds", { "filter[app]": appID, "filter[preReleaseVersion]": train.id, limit: 200 }) : [];
  const sequence = Math.max(0, ...builds.map(build => Number.parseInt(build.attributes.version, 10) || 0));
  const localCounters = path.join(buildRoot, "build-numbers.json");
  const counters = fs.existsSync(localCounters) ? JSON.parse(fs.readFileSync(localCounters, "utf8")) : {};
  return { version, build: Math.max(sequence, counters[version] ?? 0) + 1, counters, localCounters };
}

function validateProfile(target, profile, team, work, fingerprint) {
  const file = path.join(work, target.title + ".mobileprovision");
  fs.writeFileSync(file, Buffer.from(profile, "base64"), { mode: 0o600 });
  const plist = path.join(work, target.title + ".plist");
  capture("security", ["cms", "-D", "-i", file, "-o", plist]);
  const raw = capture("plutil", ["-convert", "xml1", "-o", "-", plist]);
  // plutil JSON does not serialize plist Date or Data values.
  const extract = (key, type = "raw") => capture("plutil", ["-extract", key, type, "-o", "-", plist]).trim();
  const entitlements = JSON.parse(extract("Entitlements", "json"));
  const expiry = new Date(extract("ExpirationDate"));
  const prefixes = JSON.parse(extract("ApplicationIdentifierPrefix", "json"));
  const teams = JSON.parse(extract("TeamIdentifier", "json"));
  const checks = {
    "team": teams.includes(team),
    "Bundle ID": prefixes.some(prefix => entitlements["application-identifier"] === prefix + "." + target.id),
    "App Group association": entitlements["com.apple.security.application-groups"]?.includes(groupID),
    "App Store distribution": entitlements["get-task-allow"] === false && entitlements["beta-reports-active"] &&
      !raw.includes("<key>ProvisionedDevices</key>"),
    "expiry": expiry > new Date()
  };
  if (target.cloud) {
    const allowedServices = entitlements["com.apple.developer.icloud-services"];
    checks["iCloud Documents"] = allowedServices === "*" || allowedServices?.includes("CloudDocuments");
    checks["iCloud container association"] = entitlements["com.apple.developer.ubiquity-container-identifiers"]?.includes(cloudID) &&
      entitlements["com.apple.developer.icloud-container-identifiers"]?.includes(cloudID);
  }
  const failed = Object.entries(checks).filter(([, valid]) => !valid).map(([check]) => check);
  if (failed.length) throw new Error(target.title + " App Store profile failed: " + failed.join(", "));
  if (fingerprint) {
    const certificates = raw.match(/<key>DeveloperCertificates<\/key>\s*<array>([\s\S]*?)<\/array>/)?.[1] ?? "";
    const matches = [...certificates.matchAll(/<data>([\s\S]*?)<\/data>/g)]
      .some(([, data]) => new X509Certificate(Buffer.from(data, "base64")).fingerprint256 === fingerprint);
    if (!matches) throw new Error(target.title + " profile uses a different distribution certificate.");
  }
  return { file, id: extract("UUID"), name: extract("Name") };
}

async function appleStatus(asc, credentials) {
  const app = (await asc("apps", { "filter[bundleId]": bundleID }))
    .find(item => item.attributes.bundleId === bundleID);
  console.log("App Store Connect record:", app ? `found (${app.attributes.primaryLocale})` : "missing");
  const checks = await Promise.all(targets.map(async target => {
    const bundle = (await asc("bundleIds", { "filter[identifier]": target.id }))
      .find(item => item.attributes.identifier === target.id);
    const caps = bundle ? await asc(`bundleIds/${bundle.id}/bundleIdCapabilities`) : [];
    const capabilityTypes = new Set(caps.map(item => item.attributes.capabilityType));
    const ready = capabilityTypes.has("APP_GROUPS") && (!target.cloud || capabilityTypes.has("ICLOUD"));
    console.log(`${target.title}: ${ready ? "capabilities enabled" : "capabilities still pending"} (${[...capabilityTypes].join(", ") || "none"})`);
    return { bundle, ready };
  }));
  const profiles = credentials.config["wa-wubi"]?.provisioningProfiles;
  for (const target of targets) console.log(`${target.title} local profile: ${profiles?.[target.slot] ? "present" : "missing"}`);
  return { app, bundles: checks.map(check => check.bundle), capsReady: checks.every(check => check.ready),
    profilesReady: targets.every(target => profiles?.[target.slot]), profiles };
}

function distributionFingerprint(credentials, work) {
  const p12 = path.join(work, "distribution.p12");
  if (!credentials.distribution?.p12Base64 || !credentials.distribution.password) {
    throw new Error("Missing common Apple Distribution certificate.");
  }
  fs.writeFileSync(p12, Buffer.from(credentials.distribution.p12Base64, "base64"), { mode: 0o600 });
  const argumentsForP12 = ["pkcs12", "-in", p12, "-nokeys", "-clcerts", "-passin", "stdin"];
  const password = credentials.distribution.password + "\n";
  let pem;
  try {
    pem = capture("openssl", argumentsForP12, password);
  } catch {
    pem = capture("openssl", [...argumentsForP12, "-legacy"], password);
  }
  return new X509Certificate(pem.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/)?.[0]).fingerprint256;
}

async function provision(asc, credentials, status, work) {
  const fingerprint = distributionFingerprint(credentials, work);
  const certificates = await asc("certificates", { limit: 200 });
  const signing = certificates.find(item => item.attributes.certificateContent &&
    new X509Certificate(Buffer.from(item.attributes.certificateContent, "base64")).fingerprint256 === fingerprint);
  if (!signing) throw new Error("The configured Apple Distribution certificate was not found on the developer team.");

  const profiles = { ...status.profiles };
  const saved = [];
  for (const [index, target] of targets.entries()) {
    let content = profiles[target.slot];
    if (!content) {
      const bundle = status.bundles[index];
      const existing = await asc(`bundleIds/${bundle.id}/profiles`, { limit: 200 });
      let lastRejected;
      for (const profile of existing.filter(item => item.attributes.profileType === "IOS_APP_STORE" &&
          item.attributes.profileState === "ACTIVE")) {
        const result = await asc(`profiles/${profile.id}`);
        if (!result.attributes.profileContent) continue;
        try {
          validateProfile(target, result.attributes.profileContent, credentials.team, work, fingerprint);
          content = result.attributes.profileContent;
          break;
        } catch (error) {
          lastRejected = error;
        }
      }
      if (!content) {
        if (lastRejected && !status.capsReady) throw lastRejected;
        const stamp = new Date().toISOString().slice(0, 16).replace("T", " ").replace(":", "");
        const profile = await asc("profiles", {}, { data: {
          type: "profiles",
          attributes: { name: target.title + " App Store " + stamp, profileType: "IOS_APP_STORE" },
          relationships: { bundleId: { data: { type: "bundleIds", id: bundle.id } },
            certificates: { data: [{ type: "certificates", id: signing.id }] } }
        }});
        content = profile.attributes.profileContent;
      }
    }
    const profile = validateProfile(target, content, credentials.team, work, fingerprint);
    profiles[target.slot] = content;
    saved.push({ target, profile });
  }

  const folder = path.join(os.homedir(), "Library/Mobile Documents/com~apple~CloudDocs/backup/cert/wa-wubi/provisioningProfiles");
  fs.mkdirSync(folder, { recursive: true });
  for (const { target, profile } of saved) {
    const destination = path.join(folder, target.title.replaceAll(" ", "_") + "_App_Store_" + profile.id + ".mobileprovision");
    if (!fs.existsSync(destination)) fs.copyFileSync(profile.file, destination, fs.constants.COPYFILE_EXCL);
    if (!fs.readFileSync(destination).equals(Buffer.from(profiles[target.slot], "base64"))) {
      throw new Error("NO_MATCH for " + target.title + " provisioning profile.");
    }
    console.log(target.title + " provisioning profile: MATCH");
  }
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const app = config["wa-wubi"] ?? {};
  config["wa-wubi"] = { ...app, appStoreUrl: "https://apps.apple.com/app/id" + status.app.id,
    provisioningProfiles: { ...app.provisioningProfiles, ...profiles } };
  const temporary = configPath + "." + randomBytes(8).toString("hex");
  try {
    fs.writeFileSync(temporary, JSON.stringify(config, null, 2) + "\n", { mode: 0o600, flag: "wx" });
    fs.renameSync(temporary, configPath);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

function withSigning(credentials, profiles, work, action) {
  const p12 = path.join(work, "distribution.p12");
  const keychain = path.join(work, "release.keychain-db");
  const password = randomBytes(32).toString("base64");
  const installed = [];
  const keychains = capture("security", ["list-keychains", "-d", "user"]).match(/"[^"]+"/g)?.map(value => value.slice(1, -1)) ?? [];
  const profilesDir = path.join(os.homedir(), "Library/Developer/Xcode/UserData/Provisioning Profiles");
  if (!credentials.distribution?.p12Base64 || !credentials.distribution.password) throw new Error("Missing common Apple Distribution certificate.");
  fs.writeFileSync(p12, Buffer.from(credentials.distribution.p12Base64, "base64"), { mode: 0o600 });
  try {
    // Capture these commands to keep credentials out of subprocess error output.
    capture("security", ["create-keychain", "-p", password, keychain]);
    capture("security", ["set-keychain-settings", "-lut", "7200", keychain]);
    capture("security", ["unlock-keychain", "-p", password, keychain]);
    capture("security", ["import", p12, "-k", keychain, "-P", credentials.distribution.password, "-T", "/usr/bin/codesign"]);
    capture("security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain]);
    capture("security", ["list-keychains", "-d", "user", "-s", keychain, ...keychains]);
    fs.mkdirSync(profilesDir, { recursive: true });
    for (const profile of profiles) {
      const destination = path.join(profilesDir, profile.id + ".mobileprovision");
      if (fs.existsSync(destination)) {
        if (!fs.readFileSync(destination).equals(fs.readFileSync(profile.file))) throw new Error("A different profile already uses the same UUID.");
      } else {
        fs.copyFileSync(profile.file, destination, fs.constants.COPYFILE_EXCL);
        installed.push(destination);
      }
    }
    return action();
  } finally {
    try {
      if (fs.existsSync(keychain)) {
        capture("security", ["list-keychains", "-d", "user", "-s", ...keychains]);
        capture("security", ["delete-keychain", keychain]);
      }
    } finally {
      for (const file of installed) fs.rmSync(file);
    }
  }
}

function exportIPA(credentials, profiles, plan, work) {
  const destination = path.join(buildRoot, plan.version + "-" + plan.build);
  fs.mkdirSync(destination, { recursive: false });
  const archive = path.join(destination, "WAWubiMobile.xcarchive");
  const exportPath = path.join(destination, "export");
  const options = path.join(work, "ExportOptions.plist");
  const config = { method: "app-store-connect", destination: "export", signingStyle: "manual",
    teamID: credentials.team, signingCertificate: "Apple Distribution", manageAppVersionAndBuildNumber: false,
    provisioningProfiles: Object.fromEntries(targets.map((target, index) => [target.id, profiles[index].name])) };
  run("plutil", ["-convert", "xml1", "-o", options, "-"], { input: JSON.stringify(config), stdio: ["pipe", "inherit", "inherit"] });
  withSigning(credentials, profiles, work, () => {
    run("xcodegen", ["generate", "--spec", "project-ios.yml"]);
    const project = path.join(root, "WAWubiMobile.xcodeproj");
    run("xcodebuild", ["-project", project, "-scheme", "WAWubiMobile", "-configuration", "Release",
      "-destination", "generic/platform=iOS", "-derivedDataPath", path.join(buildRoot, "DerivedData"),
      "-archivePath", archive, `DEVELOPMENT_TEAM=${credentials.team}`, "CODE_SIGN_STYLE=Manual",
      "CODE_SIGN_IDENTITY=Apple Distribution", `WA_WUBI_APP_PROFILE=${profiles[0].name}`,
      `WA_WUBI_KEYBOARD_PROFILE=${profiles[1].name}`, `MARKETING_VERSION=${plan.version}`,
      `CURRENT_PROJECT_VERSION=${plan.build}`, "archive"]);
    run("xcodebuild", ["-exportArchive", "-archivePath", archive, "-exportOptionsPlist", options, "-exportPath", exportPath]);
    const app = path.join(archive, "Products/Applications/WAWubiMobile.app");
    run("codesign", ["--verify", "--deep", "--strict", app]);
  });
  const files = fs.readdirSync(exportPath).filter(name => name.endsWith(".ipa"));
  if (files.length !== 1) throw new Error("Expected a single exported IPA.");
  return path.join(exportPath, files[0]);
}

function fastlaneKey(credentials, work) {
  const keyPath = path.join(work, "asc.json");
  fs.writeFileSync(keyPath, JSON.stringify({ key_id: credentials.key.keyId, issuer_id: credentials.key.issuerId,
    key: Buffer.from(credentials.key.privateKeyBase64, "base64").toString("utf8"), in_house: false }), { mode: 0o600 });
  return keyPath;
}

const fastlaneEnvironment = { ...process.env, FASTLANE_SKIP_UPDATE_CHECK: "1", FASTLANE_OPT_OUT_USAGE: "1" };
function deliver(keyPath, version, options) {
  const workspace = path.dirname(keyPath);
  const fastlaneFolder = path.join(workspace, "fastlane");
  fs.mkdirSync(fastlaneFolder, { recursive: true });
  fs.writeFileSync(path.join(fastlaneFolder, "Deliverfile"), "# Options are supplied by release_ios.mjs.\n");
  run("fastlane", ["deliver", "--api_key_path", keyPath, "--app_identifier", bundleID, "--platform", "ios",
    "--app_version", version, "--metadata_path", path.join(appStore, "Metadata"),
    "--screenshots_path", path.join(appStore, "Upload"), "--force", "true",
    "--precheck_include_in_app_purchases", "false", ...options],
  { cwd: workspace, env: fastlaneEnvironment });
}

async function main() {
  const [lane = "check", ...args] = process.argv.slice(2);
  const parsed = new Set(args.filter(arg => ["--online", "--automatic-release"].includes(arg)));
  const version = args.find(arg => arg.startsWith("--version="))?.split("=")[1];
  const group = args.find(arg => arg.startsWith("--internal-group="))?.slice("--internal-group=".length);
  if (!["check", "plan", "provision", "metadata", "archive", "testflight", "app-store"].includes(lane) ||
      args.some(arg => !parsed.has(arg) && !arg.startsWith("--version=") && !arg.startsWith("--internal-group=")) ||
      (group && lane !== "testflight") || (parsed.has("--automatic-release") && lane !== "app-store")) {
    throw new Error("Usage: node script/release_ios.mjs check [--online] | plan | provision | metadata | archive | testflight [--internal-group=NAME] | app-store [--automatic-release] [--version=X.Y.Z]");
  }
  validateMaterials();
  if (lane === "check" && !parsed.has("--online")) return;
  const credentials = loadCredentials();
  const asc = ascClient(credentials.key);
  const status = await appleStatus(asc, credentials);
  if (lane === "plan" && status.app) {
    for (const mode of ["testflight", "app-store"]) {
      const next = await chooseVersion(asc, status.app.id, version, mode);
      console.log(`${mode}: next iOS ${next.version} (${next.build})`);
    }
    return;
  }
  if (!status.app || !status.bundles.every(Boolean) || (!["provision", "metadata"].includes(lane) && !status.profilesReady)) {
    throw new Error("Complete Apple account and signing preparation before archiving or uploading.");
  }
  fs.mkdirSync(buildRoot, { recursive: true });
  const lock = path.join(buildRoot, ".release-lock");
  fs.mkdirSync(lock);
  const work = fs.mkdtempSync(path.join(buildRoot, "private-"));
  fs.chmodSync(work, 0o700);
  try {
    if (lane === "provision") {
      await provision(asc, credentials, status, work);
      return;
    }
    if (lane === "metadata") {
      const { version: draftVersion } = await chooseVersion(asc, status.app.id, version, "app-store");
      deliver(fastlaneKey(credentials, work), draftVersion,
        ["--skip_binary_upload", "true", "--submit_for_review", "false", "--run_precheck_before_submit", "false"]);
      return;
    }
    const fingerprint = distributionFingerprint(credentials, work);
    const profiles = targets.map(target => validateProfile(target, status.profiles[target.slot], credentials.team, work, fingerprint));
    if (lane === "check") return;
    const appID = status.app.id;
    if (group) {
      const groups = await asc(`apps/${appID}/betaGroups`, { "filter[isInternalGroup]": "true", limit: 200 });
      if (!groups.some(item => item.attributes.name === group)) throw new Error("TestFlight group is not an existing internal group.");
    }
    const plan = await chooseVersion(asc, appID, version, lane);
    console.log(`iOS ${plan.version} (${plan.build}) · ${lane}`);
    plan.counters[plan.version] = plan.build;
    const counterTemp = plan.localCounters + ".tmp";
    fs.writeFileSync(counterTemp, JSON.stringify(plan.counters));
    fs.renameSync(counterTemp, plan.localCounters);
    const ipa = exportIPA(credentials, profiles, plan, work);
    if (lane === "archive") {
      console.log("Signed IPA:", ipa);
      return;
    }
    const keyPath = fastlaneKey(credentials, work);
    if (lane === "testflight") {
      const options = ["pilot", "upload", "--api_key_path", keyPath, "--app_identifier", bundleID, "--ipa", ipa];
      if (group) {
        options.push("--groups", group, "--distribute_external", "false", "--changelog", read("TestFlight.zh-Hans.txt"));
      } else {
        options.push("--skip_waiting_for_build_processing", "true");
      }
      run("fastlane", options, { env: fastlaneEnvironment });
    } else {
      deliver(keyPath, plan.version, ["--ipa", ipa, "--build_number", String(plan.build),
        "--submit_for_review", "true", "--automatic_release", String(parsed.has("--automatic-release"))]);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
    fs.rmdirSync(lock);
  }
}

main().catch(error => {
  // Child process errors may include the invoked command and private arguments.
  console.error(error.cmd || error.status !== undefined ? `Release subprocess failed (exit ${error.status ?? "unknown"}).` : error.message);
  process.exitCode = 1;
});
