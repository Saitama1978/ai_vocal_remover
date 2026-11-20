import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:ffmpeg_kit_flutter_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_audio/return_code.dart';

void main() {
  runApp(const VocalRemoverApp());
}

class VocalRemoverApp extends StatefulWidget {
  const VocalRemoverApp({super.key});

  @override
  State<VocalRemoverApp> createState() => _VocalRemoverAppState();
}

class _VocalRemoverAppState extends State<VocalRemoverApp> {
  ThemeMode _themeMode = ThemeMode.dark; // Default Dark Mode

  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Vocal Remover',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.cyan,
        useMaterial3: true,
      ),
      home: HomeScreen(
        isDarkMode: _themeMode == ThemeMode.dark,
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const HomeScreen({
    super.key,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Engine Mode: false = Offline FFmpeg, true = AI Cloud API
  bool _useCloudAI = false;
  final TextEditingController _apiUrlController = TextEditingController(
    text: 'https://hf.space/embed/abidlabs/music-separation/api/predict',
  );

  String? _inputFilePath;
  String? _inputFileName;
  String? _vocalOutputPath;
  String? _musicOutputPath;

  bool _isProcessing = false;
  String _statusMessage = 'Pumili ng kanta (MP3, WAV, M4A) para simulan.';

  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _currentlyPlaying;

  @override
  void dispose() {
    _audioPlayer.dispose();
    _apiUrlController.dispose();
    super.dispose();
  }

  Future<void> _pickAudioFile() async {
    await _stopAudio();
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _inputFilePath = result.files.single.path!;
        _inputFileName = result.files.single.name;
        _vocalOutputPath = null;
        _musicOutputPath = null;
        _statusMessage = 'Handa nang iproseso: $_inputFileName';
      });
    }
  }

  void _resetAll() async {
    await _stopAudio();
    setState(() {
      _inputFilePath = null;
      _inputFileName = null;
      _vocalOutputPath = null;
      _musicOutputPath = null;
      _isProcessing = false;
      _statusMessage = 'Pumili ng kanta (MP3, WAV, M4A) para simulan.';
    });
  }

  Future<void> _processAudio() async {
    if (_inputFilePath == null) return;
    await _stopAudio();

    setState(() {
      _isProcessing = true;
      _vocalOutputPath = null;
      _musicOutputPath = null;
      _statusMessage = _useCloudAI
          ? 'Ina-upload sa AI Cloud Engine... Maghintay ng 30-60 segundo.'
          : 'Pinoproseso gamit ang Offline DSP Engine...';
    });

    if (_useCloudAI) {
      await _processWithCloudAI();
    } else {
      await _processWithOfflineFFmpeg();
    }
  }

  /// ENGINE 1: 100% Offline Stereo Phase Cancellation + Bandpass Vocal Isolation
  Future<void> _processWithOfflineFFmpeg() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final baseName = _inputFileName!.replaceAll(RegExp(r'\.[^\.]+$'), '');
      final musicOut = '${tempDir.path}/${baseName}_MinusOne_Offline.mp3';
      final vocalOut = '${tempDir.path}/${baseName}_Vocals_Offline.mp3';

      // Tanggalin ang lumang temp files kung meron
      if (File(musicOut).existsSync()) File(musicOut).deleteSync();
      if (File(vocalOut).existsSync()) File(vocalOut).deleteSync();

      // Command 1: Minus One (Center-channel stereo phase cancellation)
      final cmdMusic =
          '-i "$_inputFilePath" -af "pan=stereo|c0=c0-c1|c1=c1-c0" -q:a 2 "$musicOut"';
      final sessionMusic = await FFmpegKit.execute(cmdMusic);
      final returnCodeMusic = await sessionMusic.getReturnCode();

      // Command 2: Vocals Isolation (Center extract + vocal frequency bandpass)
      final cmdVocal =
          '-i "$_inputFilePath" -af "pan=mono|c0=0.5*c0+0.5*c1,highpass=f=200,lowpass=f=3500" -q:a 2 "$vocalOut"';
      final sessionVocal = await FFmpegKit.execute(cmdVocal);
      final returnCodeVocal = await sessionVocal.getReturnCode();

      if (ReturnCode.isSuccess(returnCodeMusic) &&
          ReturnCode.isSuccess(returnCodeVocal)) {
        setState(() {
          _musicOutputPath = musicOut;
          _vocalOutputPath = vocalOut;
          _isProcessing = false;
          _statusMessage = 'Tapos na! (Offline Engine)';
        });
      } else {
        setState(() {
          _isProcessing = false;
          _statusMessage = 'Nagka-error sa Offline FFmpeg processing.';
        });
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Error: $e';
      });
    }
  }

  /// ENGINE 2: AI Cloud Separation (Demucs / Gradio REST Endpoint)
  Future<void> _processWithCloudAI() async {
    try {
      final bytes = await File(_inputFilePath!).readAsBytes();
      final base64Audio = 'data:audio/mp3;base64,${base64Encode(bytes)}';

      final response = await http
          .post(
            Uri.parse(_apiUrlController.text.trim()),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'data': [
                {'name': _inputFileName, 'data': base64Audio}
              ]
            }),
          )
          .timeout(const Duration(minutes: 3));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final dataList = decoded['data'] as List;

        final tempDir = await getTemporaryDirectory();
        final baseName = _inputFileName!.replaceAll(RegExp(r'\.[^\.]+$'), '');
        final vocalOut = '${tempDir.path}/${baseName}_Vocals_AI.wav';
        final musicOut = '${tempDir.path}/${baseName}_MinusOne_AI.wav';

        await _saveBase64OrUrlToFile(dataList[0], vocalOut);
        await _saveBase64OrUrlToFile(dataList[1], musicOut);

        setState(() {
          _vocalOutputPath = vocalOut;
          _musicOutputPath = musicOut;
          _isProcessing = false;
          _statusMessage = 'Tapos na! (AI Cloud Quality)';
        });
      } else {
        setState(() {
          _isProcessing = false;
          _statusMessage =
              'Cloud Server Busy (HTTP ${response.statusCode}). Subukan ang Offline Mode o ulitin mamaya.';
        });
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage =
            'Walang koneksyon sa AI Server. Gamitin muna ang Offline Mode.';
      });
    }
  }

  Future<void> _saveBase64OrUrlToFile(dynamic item, String outPath) async {
    String raw = item is Map ? (item['data'] ?? item['url'] ?? '') : item.toString();
    if (raw.startsWith('data:')) {
      final base64Str = raw.split(',').last;
      await File(outPath).writeAsBytes(base64Decode(base64Str));
    } else if (raw.startsWith('http')) {
      final res = await http.get(Uri.parse(raw));
      await File(outPath).writeAsBytes(res.bodyBytes);
    }
  }

  Future<void> _togglePlay(String tag, String filePath) async {
    if (_currentlyPlaying == tag) {
      await _stopAudio();
    } else {
      await _audioPlayer.stop();
      await _audioPlayer.play(DeviceFileSource(filePath));
      setState(() {
        _currentlyPlaying = tag;
      });
      _audioPlayer.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() => _currentlyPlaying = null);
        }
      });
    }
  }

  Future<void> _stopAudio() async {
    await _audioPlayer.stop();
    if (mounted) {
      setState(() => _currentlyPlaying = null);
    }
  }

  Future<void> _saveToDownloads(String sourcePath, String label) async {
    try {
      await Permission.storage.request();
      Directory downloadsDir = Directory('/storage/emulated/0/Download');
      if (!downloadsDir.existsSync()) {
        final fallback = await getExternalStorageDirectory();
        downloadsDir = fallback ?? await getApplicationDocumentsDirectory();
      }

      final fileName = sourcePath.split('/').last;
      final destPath = '${downloadsDir.path}/$fileName';
      await File(sourcePath).copy(destPath);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Na-save na ang $label sa Downloads:\n$fileName'),
          backgroundColor: Colors.green.shade700,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Hindi ma-save ang file: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Vocal & Music Remover'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: widget.isDarkMode ? 'Light Mode' : 'Dark Mode',
            icon: Icon(widget.isDarkMode ? Icons.light_mode : Icons.dark_mode),
            onPressed: widget.onToggleTheme,
          ),
          IconButton(
            tooltip: 'Clear / Reset',
            icon: const Icon(Icons.refresh),
            onPressed: _resetAll,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ENGINE MODE SELECTOR CARD
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          SwitchListTile(
                            title: Text(
                              _useCloudAI
                                  ? 'AI Cloud Engine (Online - Studio Quality)'
                                  : 'Offline DSP Engine (No Internet Needed)',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text(
                              _useCloudAI
                                  ? 'Pinakamalinis na hiwalay ng boses gamit ang AI server.'
                                  : 'Mabilis at gumagana kahit walang internet connection.',
                            ),
                            secondary: Icon(
                              _useCloudAI ? Icons.cloud_sync : Icons.offline_bolt,
                              size: 32,
                            ),
                            value: _useCloudAI,
                            onChanged: _isProcessing
                                ? null
                                : (val) => setState(() => _useCloudAI = val),
                          ),
                          if (_useCloudAI)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              child: TextField(
                                controller: _apiUrlController,
                                decoration: const InputDecoration(
                                  labelText: 'AI Endpoint URL (HuggingFace/Gradio)',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // FILE PICKER BUTTON
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _pickAudioFile,
                    icon: const Icon(Icons.audio_file),
                    label: Text(
                      _inputFileName ?? 'Pumili ng Audio File (MP3 / M4A / WAV)',
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // PROCESS ACTION BUTTON
                  FilledButton.icon(
                    onPressed: (_inputFilePath == null || _isProcessing)
                        ? null
                        : _processAudio,
                    icon: _isProcessing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high),
                    label: Text(_isProcessing
                        ? 'Pinoproseso...'
                        : 'Ihiwalay ang Vocals at Minus One'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // STATUS BOX
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                    ),
                    child: Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // OUTPUT RESULTS: MINUS ONE & VOCALS
                  if (_musicOutputPath != null)
                    _buildResultCard(
                      title: 'Instrumental / Minus One',
                      icon: Icons.music_note,
                      tag: 'music',
                      filePath: _musicOutputPath!,
                    ),
                  if (_vocalOutputPath != null) ...[
                    const SizedBox(height: 12),
                    _buildResultCard(
                      title: 'Vocals Only (Acapella)',
                      icon: Icons.mic,
                      tag: 'vocal',
                      filePath: _vocalOutputPath!,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // DEVELOPER FOOTER
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).dividerColor,
                  width: 0.5,
                ),
              ),
            ),
            child: const Text(
              'Developed by Renante Fullo',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard({
    required String title,
    required IconData icon,
    required String tag,
    required String filePath,
  }) {
    final bool isPlaying = _currentlyPlaying == tag;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(icon, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton.filledTonal(
              tooltip: isPlaying ? 'Stop' : 'Play Preview',
              icon: Icon(isPlaying ? Icons.stop : Icons.play_arrow),
              onPressed: () => _togglePlay(tag, filePath),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Save to Downloads',
              icon: const Icon(Icons.download),
              onPressed: () => _saveToDownloads(filePath, title),
            ),
          ],
        ),
      ),
    );
  }
}
