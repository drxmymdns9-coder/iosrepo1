# A downloaded episode "ends" at once and plays the next one (2026-10-12, iPhone, LiveContainer)

**Report:** "ep 208 of One Piece gets skipped automatically no matter what I do", and offline it
"doesn't register as being downloaded": airplane mode gives "Finding a stream…" and then a
timeout, while two other downloaded shows play fine offline.

**Log (in-app diagnostics):** every time 208 opened it played the saved copy, then this:

```
Downloaded · kiwi · animepahe ready, duration 24:00
seek resume: 0:00 → 1:01
Downloaded · kiwi · animepahe played to the end      (0.7 s later)
next episode 209
```

Autoplay then opened 209, which was not saved: online it streamed, offline no server answered.

## Diagnosis

The saved copy came from Miruro's kiwi server (Kwik). Kwik's playlists leave the AES IV out, and
the IV Kwik means is the number in each segment's name (`segment-135-…` → IV 135), not the media
sequence number a player falls back to. Android's `KwikPlaylistDataSource` explains the result:
every segment after the first decrypts with a broken PAT, so started anywhere but 0:00 the
stream has no tracks, and the item "plays to the end" straight away. The other two shows came
from other servers, or were played from the start.

Streaming was fine because `StreamProxy` writes the IVs out (`StreamRewrite.explicitKwikIVs`).
Downloads saved the playlist untouched, and `HLSDownload.plan` renamed the segments
(`s00000.ts`…), so the numbers were gone. They also kept image-disguised segments (Miruro's
bee · HD-1) disguised, which the proxy unwraps when streaming.

## Fix

- `HLSDownload.plan` writes Kwik's IVs out before it renames the segments.
- Segments are saved without a disguise (`HLSDownload.unwrap`, the proxy's `payloadOffset`).
- The watch page also plays a saved copy in the other audio, but only when no server can be
  reached, so online the viewer still gets the audio they picked.

Kwik copies saved before the fix can't be repaired (the names they need are gone): delete
them and download them again.
