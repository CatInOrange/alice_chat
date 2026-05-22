package com.tencent.cloud.asr.plugin.asr_plugin;

import android.content.Context;
import com.tencent.aai.log.AAILogger;
import com.tencent.aai.AAIClient;
import com.tencent.aai.audio.data.AudioRecordDataSource;
import com.tencent.aai.audio.data.PcmAudioDataSource;
import com.tencent.aai.auth.AbsCredentialProvider;
import com.tencent.aai.auth.LocalCredentialProvider;
import com.tencent.aai.model.AudioRecognizeConfiguration;
import com.tencent.aai.model.AudioRecognizeRequest;

import java.io.DataOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.util.Map;
import java.util.HashMap;

public class ASRController {

    AAIClient _client = null;
    ASRControllerConfig _config = null;
    ASRControllerObserver _observer = null;
    PcmAudioDataSource _datasource = null;

    ASRController(Context context, ASRControllerConfig config) {
        _config = config;
        _client = new AAIClient(context, config.appID, config.projectID, config.secretID, config.secretKey, config.token);
    }

    public void setObserver(ASRControllerObserver observer) {
        _observer = observer;
    }

    public void setDataSource(ASRControllerDataSource datasource) {
        _datasource = datasource;
    }

    public void start() {
        AAILogger.setLogLevel(AAILogger.DEBUG_LEVEL);
        if(_datasource == null){
            _datasource = new AudioRecordDataSource(_config.is_save_audio_file);
            if (_config.is_save_audio_file) {
                _observer.setAudioFile(_config.audio_file_path);
            }
        }
        AudioRecognizeRequest.Builder requestBuilder = new AudioRecognizeRequest.Builder()
                .pcmAudioDataSource(_datasource)
                .setEngineModelType(_config.engine_model_type)
                .setFilterDirty(_config.filter_dirty)
                .setFilterModal(_config.filter_modal)
                .setFilterPunc(_config.filter_punc)
                .setConvert_num_mode(_config.convert_num_mode)
                .setHotWordId(_config.hotword_id)
                .setCustomizationId(_config.customization_id)
                .setVadSilenceTime(_config.vad_silence_time)
                .setNeedvad(_config.needvad)
                .setWordInfo(_config.word_info)
                .setReinforceHotword(_config.reinforce_hotword)
                .setNoiseThreshold(_config.noise_threshold);

        Map<String, Object> customParams = _config.getCustomParams();
        if (customParams != null && !customParams.isEmpty()) {
            for (Map.Entry<String, Object> entry : customParams.entrySet()) {
                requestBuilder.setApiParam(entry.getKey(), entry.getValue());
            }
        }
        AudioRecognizeRequest request = requestBuilder.build();

        AudioRecognizeConfiguration configuration = new AudioRecognizeConfiguration.Builder()
                .isCompress(_config.is_compress)
                .setSilentDetectTimeOut(_config.silence_detect)
                .audioFlowSilenceTimeOut(_config.silence_detect_duration)
                .build();
        _client.startAudioRecognize(request, _observer, _observer, configuration);
    }

    public void cancel() {
        _client.cancelAudioRecognize();
    }

    public void stop() {
        _client.stopAudioRecognize();
    }

}
