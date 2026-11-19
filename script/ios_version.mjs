const initialVersion = "1.0.1";
const maxComponent = 999;

function components(version) {
  if (!/^\d+(?:\.\d+){0,2}$/.test(version)) throw new Error("Invalid Apple version: " + version);
  const [major, minor = 0, patch = 0] = version.split(".").map(Number);
  return [major, minor, patch];
}

function compare(left, right) {
  const [a, b, c] = components(left);
  const [x, y, z] = components(right);
  return a - x || b - y || c - z;
}

export function nextIOSVersion(usedVersions, requestedVersion) {
  const latest = ["1.0.0", ...usedVersions].sort(compare).at(-1);
  if (requestedVersion !== undefined) {
    const [major, minor, patch] = components(requestedVersion);
    if (requestedVersion !== [major, minor, patch].join(".") ||
        minor > maxComponent || patch > maxComponent || compare(requestedVersion, initialVersion) < 0) {
      throw new Error("Use an iOS version of 1.0.1 or later with three components and minor/patch at most 999.");
    }
    if (compare(requestedVersion, latest) <= 0) throw new Error("The requested iOS version has already been used or superseded.");
    return requestedVersion;
  }
  const [major, minor, patch] = components(latest);
  if (patch < maxComponent) return `${major}.${minor}.${patch + 1}`;
  if (minor < maxComponent) return `${major}.${minor + 1}.0`;
  return `${major + 1}.0.0`;
}
