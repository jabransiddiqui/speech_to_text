import Flutter
import UIKit
import Speech
import os.log
import Try

public enum SwiftSpeechToTextMethods: String {
    case has_permission
    case initialize
    case listen
    case stop
    case cancel
    case locales
    case unknown // just for testing
}

public enum SwiftSpeechToTextCallbackMethods: String {
    case textRecognition
    case notifyStatus
    case notifyError
    case soundLevelChange
    case bufferBytesReceived
}

public enum SpeechToTextStatus: String {
    case listening
    case notListening
    case unavailable
    case available
    case done
    case doneNoResult
}

public enum SpeechToTextErrors: String {
    case onDeviceError
    case noRecognizerError
    case listenFailedError
    case missingOrInvalidArg
}

public enum ListenMode: Int {
    case deviceDefault = 0
    case dictation = 1
    case search = 2
    case confirmation = 3
}

struct SpeechRecognitionWords : Codable {
    let recognizedWords: String
    let confidence: Decimal
}

struct SpeechRecognitionResult : Codable {
    let alternates: [SpeechRecognitionWords]
    let finalResult: Bool
}

struct SpeechRecognitionError : Codable {
    let errorMsg: String
    let permanent: Bool
}

enum SpeechToTextError: Error {
    case runtimeError(String)
}


@available(iOS 10.0, *)
public class SwiftSpeechToTextPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var registrar: FlutterPluginRegistrar
    private var recognizer: SFSpeechRecognizer?
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var currentTask: SFSpeechRecognitionTask?
    private var listeningSound: AVAudioPlayer?
    private var successSound: AVAudioPlayer?
    private var cancelSound: AVAudioPlayer?
    private var previousLocale: Locale?
    private var onPlayEnd: (() -> Void)?
    private var returnPartialResults: Bool = true
    private var failedListen: Bool = false
    private var onDeviceStatus: Bool = false
    private var listening = false
    private let audioEngine = AVAudioEngine()
    private let jsonEncoder = JSONEncoder()
    private let busForNodeTap = 0
    private let speechBufferSize: AVAudioFrameCount = 8192
    private static var subsystem = Bundle.main.bundleIdentifier!
    let mRecordFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let pluginLog = OSLog(subsystem: "com.csdcorp.speechToText", category: "plugin")
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "plugin.csdcorp.com/speech_to_text", binaryMessenger: registrar.messenger())
            let instance = SwiftSpeechToTextPlugin( channel, registrar: registrar )
            registrar.addMethodCallDelegate(instance, channel: channel )
    }
    
    init( _ channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar ) {
        self.channel = channel
        self.registrar = registrar
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case SwiftSpeechToTextMethods.has_permission.rawValue:
            hasPermission( result )
        case SwiftSpeechToTextMethods.initialize.rawValue:
            initialize( result )
        case SwiftSpeechToTextMethods.listen.rawValue:
            guard let argsArr = call.arguments as? Dictionary<String,AnyObject>,
                let partialResults = argsArr["partialResults"] as? Bool, let onDevice = argsArr["onDevice"] as? Bool, let listenModeIndex = argsArr["listenMode"] as? Int, let sampleRate = argsArr["sampleRate"] as? Int
                else {
                    DispatchQueue.main.async {
                        result(FlutterError( code: SpeechToTextErrors.missingOrInvalidArg.rawValue,
                                             message:"Missing arg partialResults, onDevice, listenMode, and sampleRate are required",
                                             details: nil ))
                    }
                    return
            }
            var localeStr: String? = nil
            if let localeParam = argsArr["localeId"] as? String {
                localeStr = localeParam
            }
            guard let listenMode = ListenMode(rawValue: listenModeIndex) else {
                DispatchQueue.main.async {
                    result(FlutterError( code: SpeechToTextErrors.missingOrInvalidArg.rawValue,
                                         message:"invalid value for listenMode, must be 0-2, was \(listenModeIndex)",
                        details: nil ))
                }
                return
            }
            
            listenForSpeech( result, localeStr: localeStr, partialResults: partialResults, onDevice: onDevice, listenMode: listenMode, sampleRate: 16000 )
        case SwiftSpeechToTextMethods.stop.rawValue:
            stopSpeech( result )
        case SwiftSpeechToTextMethods.cancel.rawValue:
            cancelSpeech( result )
        case SwiftSpeechToTextMethods.locales.rawValue:
            locales( result )
        default:
            os_log("Unrecognized method: %{PUBLIC}@", log: pluginLog, type: .error, call.method)
            DispatchQueue.main.async {
                result( FlutterMethodNotImplemented)
            }
        }
    }
    
    private func hasPermission( _ result: @escaping FlutterResult) {
        AVCaptureSession().automaticallyConfiguresApplicationAudioSession = false
        let has = SFSpeechRecognizer.authorizationStatus() == SFSpeechRecognizerAuthorizationStatus.authorized &&
        AVAudioSession.sharedInstance().recordPermission == AVAudioSession.RecordPermission.granted
        DispatchQueue.main.async {
            result( has )
        }
    }
    
    private func initialize( _ result: @escaping FlutterResult) {
        var success = false
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case SFSpeechRecognizerAuthorizationStatus.notDetermined:
            SFSpeechRecognizer.requestAuthorization({(status)->Void in
                success = status == SFSpeechRecognizerAuthorizationStatus.authorized
                if ( success ) {
                    AVAudioSession.sharedInstance().requestRecordPermission({(granted: Bool)-> Void in
                        if granted {
                            self.setupSpeechRecognition(result)
                        } else{
                            self.sendBoolResult( false, result );
                            os_log("User denied permission", log: self.pluginLog, type: .info)
                        }
                    })
                }
                else {
                    self.sendBoolResult( false, result );
                }
            });
        case SFSpeechRecognizerAuthorizationStatus.denied:
            os_log("Permission permanently denied", log: self.pluginLog, type: .info)
            sendBoolResult( false, result );
        case SFSpeechRecognizerAuthorizationStatus.restricted:
            os_log("Device restriction prevented initialize", log: self.pluginLog, type: .info)
            sendBoolResult( false, result );
        default:
            os_log("Has permissions continuing with setup", log: self.pluginLog, type: .debug)
            setupSpeechRecognition(result)
        }
    }
    
    fileprivate func sendBoolResult( _ value: Bool, _ result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            result( value )
        }
    }
    
    fileprivate func setupListeningSound() {
        listeningSound = loadSound("assets/sounds/speech_to_text_listening.m4r")
        successSound = loadSound("assets/sounds/speech_to_text_stop.m4r")
        cancelSound = loadSound("assets/sounds/speech_to_text_cancel.m4r")
    }
    
    fileprivate func loadSound( _ assetPath: String ) -> AVAudioPlayer? {
        var player: AVAudioPlayer? = nil
        let soundKey = registrar.lookupKey(forAsset: assetPath )
        guard !soundKey.isEmpty else {
            return player
        }
        if let soundPath = Bundle.main.path(forResource: soundKey, ofType:nil) {
            let soundUrl = URL(fileURLWithPath: soundPath )
            do {
                player = try AVAudioPlayer(contentsOf: soundUrl )
                player?.delegate = self
            } catch {
                // no audio
            }
        }
        return player
    }
    
    private func setupSpeechRecognition( _ result: @escaping FlutterResult) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker])
        } catch let error as NSError {
            print("Failed to set the audio session category and mode: \(error.localizedDescription)")
        }
        
        setupRecognizerForLocale( locale: Locale.current )
        guard recognizer != nil else {
            sendBoolResult( false, result );
            return
        }
        if #available(iOS 13.0, *), let localRecognizer = recognizer {
            onDeviceStatus = localRecognizer.supportsOnDeviceRecognition
        }
        recognizer?.delegate = self
       
        setupListeningSound()
        
        sendBoolResult( true, result );
    }
    
    private func setupRecognizerForLocale( locale: Locale ) {
        if ( previousLocale == locale ) {
            return
        }
        previousLocale = locale
        recognizer = SFSpeechRecognizer( locale: locale )
    }
    
    private func getLocale( _ localeStr: String? ) -> Locale {
        guard let aLocaleStr = localeStr else {
            return Locale.current
        }
        let locale = Locale(identifier: aLocaleStr)
        return locale
    }
    
    private func stopSpeech( _ result: @escaping FlutterResult) {
        if ( !listening ) {
            sendBoolResult( false, result );
            return
        }
        stopAllPlayers()
        self.currentTask?.finish()
        if let sound = successSound {
            onPlayEnd = {() -> Void in
                self.stopCurrentListen( )
                self.sendBoolResult( true, result )
                return
            }
            sound.play()
        }
        else {
            stopCurrentListen( )
            sendBoolResult( true, result );
        }
    }
    
    private func cancelSpeech( _ result: @escaping FlutterResult) {
        if ( !listening ) {
            sendBoolResult( false, result );
            return
        }
        stopAllPlayers()
        self.currentTask?.cancel()
        if let sound = cancelSound {
            onPlayEnd = {() -> Void in
                self.stopCurrentListen( )
                self.sendBoolResult( true, result )
                return
            }
            sound.play()
        }
        else {
            stopCurrentListen( )
            sendBoolResult( true, result );
        }
    }
    
    private func stopAllPlayers() {
        cancelSound?.stop()
        successSound?.stop()
        listeningSound?.stop()
    }
    
    private func stopCurrentListen( ) {
        self.currentRequest?.endAudio()
        stopAllPlayers()
        do {
            try trap {
                self.audioEngine.stop()
            }
        }
        catch {
            os_log("Error stopping engine: %{PUBLIC}@", log: pluginLog, type: .error, error.localizedDescription)
        }
        do {
            try trap {
                self.audioEngine.inputNode.removeTap(onBus: self.busForNodeTap)
            }
        }
        catch {
            os_log("Error removing trap: %{PUBLIC}@", log: pluginLog, type: .error, error.localizedDescription)
        }
       
        catch {
            os_log("Error deactivation: %{PUBLIC}@", log: pluginLog, type: .info, error.localizedDescription)
        }
        self.invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.done.rawValue )

        currentRequest = nil
        currentTask = nil
        onPlayEnd = nil
        listening = false
    }
    
    private func listenForSpeech( _ result: @escaping FlutterResult, localeStr: String?, partialResults: Bool, onDevice: Bool, listenMode: ListenMode, sampleRate: Int ) {
        if ( nil != currentTask || listening ) {
            sendBoolResult( false, result );
            return
        }
        do {
        //    let inErrorTest = true
            failedListen = false
            returnPartialResults = partialResults
            setupRecognizerForLocale(locale: getLocale(localeStr))
            guard let localRecognizer = recognizer else {
                result(FlutterError( code: SpeechToTextErrors.noRecognizerError.rawValue,
                                     message:"Failed to create speech recognizer",
                                     details: nil ))
                return
            }
            if ( onDevice ) {
                if #available(iOS 13.0, *), !localRecognizer.supportsOnDeviceRecognition {
                    result(FlutterError( code: SpeechToTextErrors.onDeviceError.rawValue,
                                         message:"on device recognition is not supported on this device",
                                         details: nil ))
                }
            }
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker])

            if let sound = listeningSound {
                self.onPlayEnd = {()->Void in
                    if ( !self.failedListen ) {
                        self.listening = true
                        self.invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.listening.rawValue )

                    }
                }
                sound.play()
            }
            self.audioEngine.reset();
           
            self.currentRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let currentRequest = self.currentRequest else {
                sendBoolResult( false, result );
                return
            }
            currentRequest.shouldReportPartialResults = true
            if #available(iOS 13.0, *), onDevice {
                currentRequest.requiresOnDeviceRecognition = true
            }
            switch listenMode {
            case ListenMode.dictation:
                currentRequest.taskHint = SFSpeechRecognitionTaskHint.dictation
                break
            case ListenMode.search:
                currentRequest.taskHint = SFSpeechRecognitionTaskHint.search
                break
            case ListenMode.confirmation:
                currentRequest.taskHint = SFSpeechRecognitionTaskHint.confirmation
                break
            default:
                break
            }
            
            self.currentTask = self.recognizer?.recognitionTask(with: currentRequest, delegate: self )
            
            audioEngine.inputNode.removeTap(onBus: self.busForNodeTap)
            let input = audioEngine.inputNode
            let inputFormat = input.outputFormat(forBus: self.busForNodeTap)
            let converter = AVAudioConverter(from: inputFormat, to: mRecordFormat)!
            let ratio: Float = Float(inputFormat.sampleRate)/Float(mRecordFormat.sampleRate)
            /*let format = recordingFormat!.commonFormat
            let theSampleRate = AVAudioSession.sharedInstance().sampleRate
            let interLeaved = recordingFormat!.isInterleaved
            let channelCount = recordingFormat!.channelCount
            let fmt = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatInt16, sampleRate: 16000, channels:channelCount, interleaved: interLeaved)!*/
            
            
            try trap {
                input.installTap(onBus: self.busForNodeTap, bufferSize: self.speechBufferSize, format: inputFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
                    let inputCallback: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    
                    let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.mRecordFormat, frameCapacity: UInt32(Float(buffer.frameCapacity) / ratio))!
                    
                    var error: NSError?
                    let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)
                    assert(status != .error)
                    
                    if (self.mRecordFormat.commonFormat == AVAudioCommonFormat.pcmFormatInt16) {
                        let data : [UInt8] = self.audioBufferToBytes(audioBuffer: convertedBuffer)
                        let channelData = FlutterStandardTypedData(bytes: NSData(bytes: data, length: data.count) as Data)
                        self.invokeFlutter( SwiftSpeechToTextCallbackMethods.bufferBytesReceived, arguments:channelData)
                    }
                    
                   
                    currentRequest.append(buffer)
                    self.updateSoundLevel( buffer: buffer )
                }
            }
        //    if ( inErrorTest ){
        //        throw SpeechToTextError.runtimeError("for testing only")
        //    }
            self.audioEngine.prepare()
            try self.audioEngine.start()
            if nil == listeningSound {
                listening = true
                self.invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.listening.rawValue )
            }
            sendBoolResult( true, result );
        }
        catch {
            failedListen = true
            os_log("Error starting listen: %{PUBLIC}@", log: pluginLog, type: .error, error.localizedDescription)
            self.invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.notListening.rawValue )
            stopCurrentListen()
            sendBoolResult( false, result );
            // ensure the not listening signal is sent in the error case
            let speechError = SpeechRecognitionError(errorMsg: "error_listen_failed", permanent: true )
            do {
                let errorResult = try jsonEncoder.encode(speechError)
                invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyError, arguments: String( data:errorResult, encoding: .utf8) )
                invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.doneNoResult.rawValue )
            } catch {
                os_log("Could not encode JSON", log: pluginLog, type: .error)
            }
        }
    }
    
    private func updateSoundLevel( buffer: AVAudioPCMBuffer) {
        guard
            let channelData = buffer.floatChannelData
            else {
                return
        }
        
        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0,
                                           to: Int(buffer.frameLength),
                                           by: buffer.stride).map{ channelDataValue[$0] }
        let frameLength = Float(buffer.frameLength)
        let rms = sqrt(channelDataValueArray.map{ $0 * $0 }.reduce(0, +) / frameLength )
        let avgPower = 20 * log10(rms)
        self.invokeFlutter( SwiftSpeechToTextCallbackMethods.soundLevelChange, arguments:avgPower )
    }
    
    // MARK:  Convert Buffer formate
    public func convertAudioBufferToFormat(orgBuffer: AVAudioPCMBuffer, newFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let oldSampleRate = orgBuffer.format.sampleRate
        let newSampleRate = newFormat.sampleRate
        let ratio: Float = Float(oldSampleRate)/Float(newSampleRate)
        let capacity = UInt32(Float(orgBuffer.frameCapacity) / ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: newFormat,
            frameCapacity: capacity) else {
                print("Failed to create new buffer")
                return nil
        }
        
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = AVAudioConverterInputStatus.haveData
            return orgBuffer
        }
        
        let converter = AVAudioConverter(from: orgBuffer.format, to: newFormat)
        converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter?.sampleRateConverterQuality = .min
        converter?.bitRateStrategy = AVAudioBitRateStrategy_Constant
        
        var error: NSError?
        let status: AVAudioConverterOutputStatus? = converter?.convert(
            to: outputBuffer,
            error: &error,
            withInputFrom: inputBlock)
        
        if status == .error {
            if let unwrappedError: NSError = error {
                print("Error \(unwrappedError)")
            }
            return nil
        }
        
        return outputBuffer
    }
    
    func audioBufferToBytes(audioBuffer: AVAudioPCMBuffer) -> [UInt8] {
        let srcLeft = audioBuffer.int16ChannelData![0]
        let bytesPerFrame = audioBuffer.format.streamDescription.pointee.mBytesPerFrame
        let numBytes = Int(bytesPerFrame * audioBuffer.frameLength)
        
        // initialize bytes by 0
        var audioByteArray = [UInt8](repeating: 0, count: numBytes)
        
        srcLeft.withMemoryRebound(to: UInt8.self, capacity: numBytes) { srcByteData in
            audioByteArray.withUnsafeMutableBufferPointer {
                $0.baseAddress!.initialize(from: srcByteData, count: numBytes)
            }
        }
        
        return audioByteArray
    }
    
    /// Build a list of localId:name with the current locale first
    private func locales( _ result: @escaping FlutterResult ) {
        var localeNames = [String]();
        let locales = SFSpeechRecognizer.supportedLocales();
        var currentLocaleId = Locale.current.identifier
        if Locale.preferredLanguages.count > 0 {
            currentLocaleId = Locale.preferredLanguages[0]
        }
        if let idName = buildIdNameForLocale(forIdentifier: currentLocaleId ) {
            localeNames.append(idName)
        }
        for locale in locales {
            if ( locale.identifier == currentLocaleId) {
                continue
            }
            if let idName = buildIdNameForLocale(forIdentifier: locale.identifier ) {
                localeNames.append(idName)
            }
        }
        DispatchQueue.main.async {
            result(localeNames)
        }
    }
    
    private func buildIdNameForLocale( forIdentifier: String ) -> String? {
        var idName: String?
        if let name = Locale.current.localizedString(forIdentifier: forIdentifier ) {
            let sanitizedName = name.replacingOccurrences(of: ":", with: " ")
            idName = "\(forIdentifier):\(sanitizedName)"
        }
        return idName
    }
    
    private func handleResult( _ transcriptions: [SFTranscription], isFinal: Bool ) {
        if ( !isFinal && !returnPartialResults ) {
            return
        }
        var speechWords: [SpeechRecognitionWords] = []
        for transcription in transcriptions {
            let words: SpeechRecognitionWords = SpeechRecognitionWords(recognizedWords: transcription.formattedString, confidence: confidenceIn( transcription))
            speechWords.append( words )
        }
        let speechInfo = SpeechRecognitionResult(alternates: speechWords, finalResult: isFinal )
        do {
            let speechMsg = try jsonEncoder.encode(speechInfo)
            if let speechStr = String( data:speechMsg, encoding: .utf8) {
                os_log("Encoded JSON result: %{PUBLIC}@", log: pluginLog, type: .debug, speechStr )
                invokeFlutter( SwiftSpeechToTextCallbackMethods.textRecognition, arguments: speechStr )
            }
        } catch {
            os_log("Could not encode JSON", log: pluginLog, type: .error)
        }
    }
    
    private func confidenceIn( _ transcription: SFTranscription ) -> Decimal {
        guard ( transcription.segments.count > 0 ) else {
            return 0;
        }
        var totalConfidence: Float = 0.0;
        for segment in transcription.segments {
            totalConfidence += segment.confidence
        }
        let avgConfidence: Float = totalConfidence / Float(transcription.segments.count )
        let confidence: Float = (avgConfidence * 1000).rounded() / 1000
        return Decimal( string: String( describing: confidence ) )!
    }
    
    private func invokeFlutter( _ method: SwiftSpeechToTextCallbackMethods, arguments: Any? ) {
        os_log("invokeFlutter %{PUBLIC}@", log: pluginLog, type: .debug, method.rawValue )
        DispatchQueue.main.async {
            self.channel.invokeMethod( method.rawValue, arguments: arguments )
        }
    }
    
}

@available(iOS 10.0, *)
extension SwiftSpeechToTextPlugin : SFSpeechRecognizerDelegate {
    public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        let availability = available ? SpeechToTextStatus.available.rawValue : SpeechToTextStatus.unavailable.rawValue
        os_log("Availability changed: %{PUBLIC}@", log: pluginLog, type: .debug, availability)
        invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: availability )
    }
}

@available(iOS 10.0, *)
extension SwiftSpeechToTextPlugin : SFSpeechRecognitionTaskDelegate {
    public func speechRecognitionDidDetectSpeech(_ task: SFSpeechRecognitionTask) {
        // Do nothing for now
    }
    
    public func speechRecognitionTaskFinishedReadingAudio(_ task: SFSpeechRecognitionTask) {
        reportError(source: "FinishedReadingAudio", error: task.error)
        os_log("Finished reading audio", log: pluginLog, type: .debug )
        invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.notListening.rawValue )
    }
    
    public func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        reportError(source: "TaskWasCancelled", error: task.error)
        os_log("Canceled reading audio", log: pluginLog, type: .debug )
        invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.notListening.rawValue )
    }
    
    public func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        reportError(source: "FinishSuccessfully", error: task.error)
        os_log("FinishSuccessfully", log: pluginLog, type: .debug )
        if ( !successfully ) {
            invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.doneNoResult.rawValue )
            if let err = task.error as NSError? {
                var errorMsg: String
                switch err.code {
                case 201:
                    errorMsg = "error_speech_recognizer_disabled"
                case 203:
                    errorMsg = "error_retry"
                case 1110:
                    errorMsg = "error_no_match"
                default:                    
                    errorMsg = "error_unknown (\(err.code))"
                }
                let speechError = SpeechRecognitionError(errorMsg: errorMsg, permanent: true )
                do {
                    let errorResult = try jsonEncoder.encode(speechError)
                    invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyError, arguments: String(data:errorResult, encoding: .utf8) )
                } catch {
                    os_log("Could not encode JSON", log: pluginLog, type: .error)
                }
            }
        }
        stopCurrentListen( )
    }
    
    public func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription) {
        os_log("HypothesizeTranscription", log: pluginLog, type: .debug )
        reportError(source: "HypothesizeTranscription", error: task.error)
        handleResult( [transcription], isFinal: false )
    }
    
    public func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition recognitionResult: SFSpeechRecognitionResult) {
        reportError(source: "FinishRecognition", error: task.error)
        os_log("FinishRecognition %{PUBLIC}@", log: pluginLog, type: .debug, recognitionResult.isFinal.description )
        let isFinal = recognitionResult.isFinal
        handleResult( recognitionResult.transcriptions, isFinal: isFinal )
    }
    
    private func reportError( source: String, error: Error?) {
        if ( nil != error) {
            os_log("%{PUBLIC}@ with error: %{PUBLIC}@", log: pluginLog, type: .debug, source, error.debugDescription)
        }
    }
}

@available(iOS 10.0, *)
extension SwiftSpeechToTextPlugin : AVAudioPlayerDelegate {
    
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,
                                            successfully flag: Bool) {
        if let playEnd = self.onPlayEnd {
            playEnd()
        }
    }
}
