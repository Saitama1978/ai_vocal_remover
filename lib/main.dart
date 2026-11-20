import 'dart:io';
import 'dart:json' if (dart.library.html) 'ignored_json.dart';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const VocalRemoverApp());
}

class VocalRemoverApp extends StatefulWidget {
  const VocalRemoverApp({super.key});

  @override
  State<VocalRemoverApp> createState() => _VocalRemoverAppState();
}

class _VocalRemoverAppState extends State<VocalRemoverApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
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
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.cyanAccent,
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
  // Naka-hardcode na ang iyong personal Hugging Face Space URL dito para hindi na i-type!
  final String _hardcodedApiUrl = 'https://saitama1978-vocal-remover.hf.space';

  String? _inputFilePath;
  String? _inputFileName;
  String? _vocalOutputPath;
  String? _musicOutputPath;

  bool _isProcessing = false;
  String _statusMessage = 'Pumili ng paboritong kanta (MP3, WAV, M4A) para simulang ihiwalay ang boses.';

  Future<void> _pickAudioFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _inputFilePath = result.files.single.path!;
        _inputFileName = result.files.single.name;
        _vocalOutputPath = null;
        _musicOutputPath = null;
        _statusMessage = 'Handa nang i-process: $_inputFileName';
      });
    }
  }

  void _resetAll() {
    setState(() {
      _inputFilePath = null;
      _inputFileName = null;
      _vocalOutputPath = null;
      _musicOutputPath = null;
      _isProcessing = false;
      _statusMessage = 'Pumili ng kanta para magsimula.';
    });
  }

  Future<void> _processAudio() async {
    if (_inputFilePath == null) return;

    String baseUrl = _hardcodedApiUrl;
    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }
    baseUrl = baseUrl.replaceAll('/api/predict', '');

    setState(() {
      _isProcessing = true;
      _vocalOutputPath = null;
      _musicOutputPath = null;
      _statusMessage = 'Ipinapadala ang kanta sa AI server... Sandali lang po.';
    });

    try {
      final uploadUri = Uri.parse('$baseUrl/upload');
      final request = http.MultipartRequest('POST', uploadUri);
      request.files.add(
        await http.MultipartFile.fromPath(
          'files',
          _inputFilePath!,
          filename: _inputFileName,
        ),
      );

      final streamedResponse = await request.send().timeout(const Duration(minutes: 3));
      final uploadResponse = await http.Response.fromStream(streamedResponse);

      if (uploadResponse.statusCode != 200) {
        setState(() {
          _isProcessing = false;
          _statusMessage = 'Nabigo ang pag-upload (HTTP ${uploadResponse.statusCode}). Pakitiyak na nagre-run ang iyong HF Space.';
        });
        return;
      }

      final uploadedData = jsonDecode(uploadResponse.body);
      final String serverFilePath = uploadedData is List
          ? uploadedData.first.toString()
          : (uploadedData['path'] ?? uploadedData['url'] ?? '').toString();

      setState(() {
        _statusMessage = 'Pinoproseso na ng AI ang musika at boses... (Maaaring tumagal ng ilang minuto)';
      });

      final predictResponse = await http.post(
        Uri.parse('$baseUrl/api/predict'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'data': [
            {'path': serverFilePath, 'orig_name': _inputFileName}
          ]
        }),
      ).timeout(const Duration(minutes: 4));

      if (predictResponse.statusCode == 200) {
        final decoded = jsonDecode(predictResponse.body);
        final dataList = decoded['data'] as List;

        final tempDir = await getTemporaryDirectory();
        final baseName = _inputFileName!.replaceAll(RegExp(r'\.[^\.]+$'), '');
        final vocalOut = '${tempDir.path}/${baseName}_Vocals.wav';
        final musicOut = '${tempDir.path}/${baseName}_MinusOne.wav';

        await _saveFileFromData(dataList[0], vocalOut, baseUrl);
        await _saveFileFromData(dataList[1], musicOut, baseUrl);

        setState(() {
          _vocalOutputPath = vocalOut;
          _musicOutputPath = musicOut;
          _isProcessing = false;
          _statusMessage = 'Tagumpay! Hiwalay na ang Vocals at Minus One.';
        });
      } else {
        setState(() {
          _isProcessing = false;
          _statusMessage = 'Nagka-problema sa AI server (HTTP ${predictResponse.statusCode}). Subukan muli.';
        });
      }
    } on TimeoutException {
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Nag-timeout ang server. Masyadong mahaba o mabigat ang kanta.';
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Nabigo ang koneksyon sa server. Suriin ang iyong internet.';
      });
    }
  }

  Future<void> _saveFileFromData(dynamic item, String outPath, String baseUrl) async {
    String raw = '';
    if (item is Map) {
      raw = (item['url'] ?? item['path'] ?? item['data'] ?? '').toString();
    } else {
      raw = item.toString();
    }

    if (raw.startsWith('data:')) {
      final base64Str = raw.split(',').last;
      await File(outPath).writeAsBytes(base64Decode(base64Str));
    } else if (raw.startsWith('http')) {
      final res = await http.get(Uri.parse(raw));
      await File(outPath).writeAsBytes(res.bodyBytes);
    } else if (raw.isNotEmpty) {
      final fileUrl = '$baseUrl/file=$raw';
      final res = await http.get(Uri.parse(fileUrl));
      await File(outPath).writeAsBytes(res.bodyBytes);
    }
  }

  Future<void> _saveToDownloads(String sourcePath) async {
    try {
      await Permission.storage.request();
      Directory downloadsDir = Directory('/storage/emulated/0/Download');
      if (!downloadsDir.existsSync()) {
        downloadsDir = await getApplicationDocumentsDirectory();
      }
      final fileName = sourcePath.split('/').last;
      final destPath = '${downloadsDir.path}/$fileName';
      await File(sourcePath).copy(destPath);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nai-save na sa Download folder: $fileName'),
          backgroundColor: Colors.teal.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Hindi ma-save: $e')),
      );
    }
  }

  @prototype
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Vocal Remover', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(widget.isDarkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
            onPressed: widget.onToggleTheme,
            tooltip: 'Palitan ang Tema',
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _resetAll,
            tooltip: 'I-reset ang Lahat',
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: widget.isDarkMode
                ? [Colors.grey.shade900, Colors.black]
                : [Colors.deepPurple.shade50, Colors.white],
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Status Card na may magandang disenyo
                    Card(
                      elevation: 4,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline_rounded, color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _statusMessage,
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // File Picker Button
                    OutlinedButton.icon(
                      onPressed: _isProcessing ? null : _pickAudioFile,
                      icon: const Icon(Icons.audio_file_rounded),
                      label: Text(
                        _inputFileName ?? 'Pumili ng Audio File (MP3, M4A, WAV)',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Process Button
                    FilledButton.icon(
                      onPressed: (_inputFilePath == null || _isProcessing) ? null : _processAudio,
                      icon: _isProcessing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                            )
                          : const Icon(Icons.auto_fix_high_rounded),
                      label: Text(
                        _isProcessing ? 'Pinoproseso ang Kanta...' : 'Ihiwalay ang Vocals at Minus One',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                    const SizedBox(height: 30),

                    // Result Cards
                    if (_musicOutputPath != null) ...[
                      _buildResultCard(
                        title: 'Minus One (Instrumental)',
                        subtitle: 'Handa nang i-download',
                        icon: Icons.music_note_rounded,
                        filePath: _musicOutputPath!,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_vocalOutputPath != null)
                      _buildResultCard(
                        title: 'Vocals Only (Boses Lang)',
                        subtitle: 'Handa nang i-download',
                        icon: Icons.mic_rounded,
                        filePath: _vocalOutputPath!,
                      ),
                  ],
                ),
              ),
            ),
            // Footer Attribution
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Developed by Renante Fullo',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required String filePath,
  }) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                ],
              ),
            ),
            IconButton.filled(
              icon: const Icon(Icons.download_rounded),
              onPressed: () => _saveToDownloads(filePath),
              tooltip: 'I-save sa Downloads',
            ),
          ],
        ),
      ),
    );
  }
}
