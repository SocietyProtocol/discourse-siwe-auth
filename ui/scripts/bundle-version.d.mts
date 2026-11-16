export const BUNDLE_URL_PATH: string
export const BUNDLE_FILE: string
export const VERSION_MODULE_FILE: string
export function bundleVersion(contents: string | Uint8Array): string
export function versionModule(version: string): string
export function committedVersion(file?: string): string | null
