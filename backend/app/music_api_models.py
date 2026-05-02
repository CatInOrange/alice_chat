from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class MusicApiModel(BaseModel):
    model_config = ConfigDict(extra='allow')


class CachedPlaybackSourceDto(MusicApiModel):
    providerId: str = ''
    sourceTrackId: str = ''
    streamUrl: str = ''
    artworkUrl: str | None = None
    mimeType: str | None = None
    headers: dict[str, str] = Field(default_factory=dict)
    expiresAt: str | None = None
    resolvedAt: str | None = None


class MusicTrackDto(MusicApiModel):
    id: str = ''
    title: str = ''
    artist: str = ''
    album: str = ''
    durationMs: int = 0
    category: str = ''
    description: str = ''
    artworkTone: str = 'twilight'
    isFavorite: bool = False
    artworkUrl: str | None = None
    preferredSourceId: str | None = None
    sourceTrackId: str | None = None
    encryptedSourceTrackId: str | None = None
    cachedPlayback: CachedPlaybackSourceDto | None = None


class MusicPlaylistDto(MusicApiModel):
    id: str = ''
    title: str = ''
    subtitle: str = ''
    tag: str = ''
    trackCount: int = 0
    artworkTone: str = 'twilight'
    isAiGenerated: bool = False


class MusicSourceRefDto(MusicApiModel):
    providerId: str = ''
    sourceTrackId: str = ''
    sourceUrl: str | None = None


class CanonicalTrackDto(MusicApiModel):
    id: str = ''
    title: str = ''
    artist: str = ''
    album: str = ''
    durationMs: int = 0
    artworkTone: str = 'twilight'
    category: str = ''
    description: str = ''
    artworkUrl: str | None = None
    sourceRefs: list[MusicSourceRefDto] = Field(default_factory=list)


class SourceCandidateDto(MusicApiModel):
    providerId: str = ''
    sourceTrackId: str = ''
    track: CanonicalTrackDto = Field(default_factory=CanonicalTrackDto)
    matchScore: float = 1.0
    available: bool = True
    sourceUrl: str | None = None


class ResolvedPlaybackSourceDto(MusicApiModel):
    providerId: str = ''
    sourceTrackId: str = ''
    streamUrl: str = ''
    artworkUrl: str | None = None
    mimeType: str | None = None
    headers: dict[str, str] = Field(default_factory=dict)
    expiresAt: str | None = None


class PlaybackQueueItemDto(MusicApiModel):
    track: MusicTrackDto = Field(default_factory=MusicTrackDto)
    candidate: SourceCandidateDto | None = None
    resolvedSource: ResolvedPlaybackSourceDto | None = None
    requestedBy: str = ''


MusicCommandType = Literal[
    'play',
    'pause',
    'resume',
    'next',
    'previous',
    'seek',
    'replaceQueue',
    'appendToQueue',
    'likeTrack',
    'unlikeTrack',
]

MusicCommandSource = Literal['manual', 'chatAi', 'system']


class MusicCommandRequest(MusicApiModel):
    type: MusicCommandType = 'play'
    source: MusicCommandSource = 'manual'
    queue: list[PlaybackQueueItemDto] = Field(default_factory=list)
    targetDeviceId: str | None = None
    requestId: str | None = None
    positionMs: int | None = None


class MusicAiPlaylistDraftDto(MusicApiModel):
    id: str = ''
    title: str = ''
    subtitle: str = ''
    description: str = ''
    tag: str = 'AI'
    artworkTone: str = 'aurora'
    isAiGenerated: bool = True
    tracks: list[MusicTrackDto] = Field(default_factory=list)
    createdAt: float | None = None
    updatedAt: float | None = None


class CustomMusicPlaylistDto(MusicApiModel):
    id: str = ''
    title: str = ''
    subtitle: str = ''
    description: str = ''
    tag: str = '我的歌单'
    artworkTone: str = 'sunset'
    tracks: list[MusicTrackDto] = Field(default_factory=list)
    createdAt: float | None = None
    updatedAt: float | None = None


class MusicStateDto(MusicApiModel):
    currentTrack: MusicTrackDto | None = None
    queue: list[PlaybackQueueItemDto] = Field(default_factory=list)
    playlists: list[MusicPlaylistDto] = Field(default_factory=list)
    recentTracks: list[MusicTrackDto] = Field(default_factory=list)
    recentPlaylists: list[MusicPlaylistDto] = Field(default_factory=list)
    likedTracks: list[MusicTrackDto] = Field(default_factory=list)
    customPlaylists: list[CustomMusicPlaylistDto] = Field(default_factory=list)
    latestAiPlaylist: MusicAiPlaylistDraftDto | None = None
    aiPlaylistHistory: list[MusicAiPlaylistDraftDto] = Field(default_factory=list)
    isPlaying: bool = False
    positionMs: int = 0
    currentPlaylistId: str | None = None
    neteaseLikedPlaylistId: str | None = None
    neteaseLikedPlaylistEncryptedId: str | None = None
    updatedAt: float | None = None


class MusicHomeDto(MusicApiModel):
    latestAiPlaylist: MusicAiPlaylistDraftDto | None = None
    aiPlaylistHistory: list[MusicAiPlaylistDraftDto] = Field(default_factory=list)
    recentTracks: list[MusicTrackDto] = Field(default_factory=list)
    recentPlaylists: list[MusicPlaylistDto] = Field(default_factory=list)
    likedTracks: list[MusicTrackDto] = Field(default_factory=list)
    customPlaylists: list[CustomMusicPlaylistDto] = Field(default_factory=list)
    neteaseLikedPlaylistId: str | None = None
    neteaseLikedPlaylistEncryptedId: str | None = None
    updatedAt: float | None = None


class MusicStatePatchDto(MusicApiModel):
    currentTrack: MusicTrackDto | None = None
    queue: list[PlaybackQueueItemDto] | None = None
    playlists: list[MusicPlaylistDto] | None = None
    recentTracks: list[MusicTrackDto] | None = None
    recentPlaylists: list[MusicPlaylistDto] | None = None
    likedTracks: list[MusicTrackDto] | None = None
    customPlaylists: list[CustomMusicPlaylistDto] | None = None
    latestAiPlaylist: MusicAiPlaylistDraftDto | None = None
    aiPlaylistHistory: list[MusicAiPlaylistDraftDto] | None = None
    isPlaying: bool | None = None
    positionMs: int | None = None
    currentPlaylistId: str | None = None
    neteaseLikedPlaylistId: str | None = None
    neteaseLikedPlaylistEncryptedId: str | None = None


class MusicProviderDto(MusicApiModel):
    providerId: str
    displayName: str
    authMode: Literal['none', 'client', 'server'] = 'client'
    supportedAuthMethods: list[str] = Field(default_factory=list)
    supportsSearch: bool = True
    supportsLyrics: bool = True
    supportsResolve: bool = True
    supportsPlaylistLookup: bool = False
    supportsUserLibrary: bool = False
    notes: str = ''


class MusicIntelligenceTrackRefDto(MusicApiModel):
    providerId: str | None = None
    trackId: str | None = None
    title: str | None = None
    artist: str | None = None
    sourceTrackId: str | None = None
    encryptedSourceTrackId: str | None = None


class MusicIntelligencePlaylistRefDto(MusicApiModel):
    providerId: str | None = None
    playlistId: str | None = None
    title: str | None = None
    sourcePlaylistId: str | None = None
    encryptedPlaylistId: str | None = None


class MusicIntelligenceRequestDto(MusicApiModel):
    song: MusicIntelligenceTrackRefDto = Field(default_factory=MusicIntelligenceTrackRefDto)
    playlist: MusicIntelligencePlaylistRefDto | None = None
    count: int = 20
    mode: str = 'fromPlayAll'
