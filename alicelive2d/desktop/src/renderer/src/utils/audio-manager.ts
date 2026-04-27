/**
 * Global audio manager for handling audio playback and interruption
 * This ensures all components share the same audio reference
 */
class AudioManager {
  private currentAudio: HTMLAudioElement | null = null;
  private currentModel: any | null = null;
  private currentLipSyncCleanup: (() => void) | null = null;

  /**
   * Set the current playing audio
   */
  setCurrentAudio(
    audio: HTMLAudioElement,
    model: any,
    lipSyncCleanup?: (() => void) | null,
  ) {
    this.currentAudio = audio;
    this.currentModel = model;
    this.currentLipSyncCleanup = lipSyncCleanup || null;
  }

  /**
   * Stop current audio playback and lip sync
   */
  stopCurrentAudioAndLipSync() {
    if (this.currentAudio) {
      console.log('[AudioManager] Stopping current audio and lip sync');
      const audio = this.currentAudio;
      
      // Stop audio playback
      audio.pause();
      audio.src = '';
      audio.load();

      // Stop Live2D lip sync
      const model = this.currentModel;
      if (model && model._wavFileHandler) {
        try {
          // Release PCM data to stop lip sync calculation in update()
          model._wavFileHandler.releasePcmData();
          console.log('[AudioManager] Called _wavFileHandler.releasePcmData()');

          // Additional reset of state variables as fallback
          model._wavFileHandler._lastRms = 0.0;
          model._wavFileHandler._sampleOffset = 0;
          model._wavFileHandler._userTimeSeconds = 0.0;
          console.log('[AudioManager] Also reset _lastRms, _sampleOffset, _userTimeSeconds as fallback');
        } catch (e) {
          console.error('[AudioManager] Error stopping/resetting wavFileHandler:', e);
        }
      } else if (model) {
        console.warn('[AudioManager] Current model does not have _wavFileHandler to stop/reset.');
      } else {
        console.log('[AudioManager] No associated model found to stop lip sync.');
      }

      if (this.currentLipSyncCleanup) {
        try {
          this.currentLipSyncCleanup();
        } catch (e) {
          console.error('[AudioManager] Error while cleaning up realtime lip sync:', e);
        }
      }

      // Clear references
      this.currentAudio = null;
      this.currentModel = null;
      this.currentLipSyncCleanup = null;
    } else {
      console.log('[AudioManager] No current audio playing to stop.');
    }
  }

  /**
   * Clear the current audio reference (called when audio ends naturally)
   */
  clearCurrentAudio(audio: HTMLAudioElement) {
    if (this.currentAudio === audio) {
      if (this.currentLipSyncCleanup) {
        try {
          this.currentLipSyncCleanup();
        } catch (e) {
          console.error('[AudioManager] Error while clearing realtime lip sync:', e);
        }
      }
      this.currentAudio = null;
      this.currentModel = null;
      this.currentLipSyncCleanup = null;
    }
  }

  /**
   * Check if there's currently playing audio
   */
  hasCurrentAudio(): boolean {
    return this.currentAudio !== null;
  }
}

// Export singleton instance
export const audioManager = new AudioManager();
