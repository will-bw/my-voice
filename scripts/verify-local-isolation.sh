#!/bin/zsh
set -eu

repo_root=${0:A:h:h}
cd "$repo_root"

plutil -lint VoiceInk/Info.plist VoiceInk/VoiceInk.local.entitlements >/dev/null

if rg -q 'SUFeedURL|SUPublicEDKey|beingpax\.github\.io/VoiceInk/appcast' VoiceInk/Info.plist; then
    print -u2 'official Sparkle metadata is still present'
    exit 1
fi

rg -q 'Personal builds must never consult or install the official VoiceInk appcast' \
    VoiceInk/App/Updates/UpdaterViewModel.swift
rg -q 'Commercial license validation is disabled in this local build' \
    VoiceInk/Features/Licensing/State/LicenseViewModel.swift
rg -q 'private let service = "com\.will\.myvoice"' \
    VoiceInk/Infrastructure/Credentials/KeychainService.swift
rg -q '"com\.will\.myvoice"' VoiceInk/App/Configuration/AppIdentity.swift
rg -Fq 'appendingPathComponent(AppIdentity.applicationSupportDirectoryName' \
    VoiceInk/Features/ModelLibrary/State/FluidAudioModelManager.swift
if rg -q 'AsrModels\.defaultCacheDirectory' \
    VoiceInk/Features/ModelLibrary/State/FluidAudioModelManager.swift \
    VoiceInk/Infrastructure/Providers/Transcription/FluidAudio/FluidAudioTranscriptionService.swift; then
    print -u2 'FluidAudio still uses its shared default model cache'
    exit 1
fi
rg -q 'com\.will\.myvoice\.VoiceInkRefineXPC' Shared/VoiceInkRefineXPCProtocol.swift
rg -q 'WHISPER_CPP_REVISION := da54572229bcf64ba367d96c7ef15770376c4280' Makefile

if rg -q 'git pull' Makefile; then
    print -u2 'the build still pulls a floating dependency revision'
    exit 1
fi

if rg -q 'appendingPathComponent\("com\.prakashjoshipax\.VoiceInk"' VoiceInk; then
    print -u2 'an official VoiceInk Application Support path is still hard-coded'
    exit 1
fi

dry_run=$(make -n local)
print -r -- "$dry_run" | rg -Fq 'com.will.myvoice.$(TARGET_NAME:rfc1034identifier)'
print -r -- "$dry_run" | rg -q 'dist/my-voice\.app'

swiftc -parse -D LOCAL_BUILD \
    VoiceInk/App/Configuration/AppIdentity.swift \
    VoiceInk/App/Updates/UpdaterViewModel.swift \
    VoiceInk/Features/Licensing/State/LicenseViewModel.swift \
    Shared/VoiceInkRefineXPCProtocol.swift

print 'Local build isolation checks passed.'
