import 'dart:io';
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
  // Ilagay dito ang base URL ng iyong Hugging Face Space o Custom Server
  // Halimbawa: https://username-demucs.hf.space
  final TextEditingController _apiUrlController = TextEditingController(
    text: 'https://your-space-name.hf.space',
  );

  String? _inputFilePath;
  String? _inputFileName;
  String? _vocalOutputPath;
  String? _musicOutputPath;

  bool _isProcessing = false;
  String _statusMessage = 'Pumili ng kanta (MP3, WAV, M4A) para ihiwalay ang boses.';

  @override
  void dispose() {
    _apiUrlController.dispose();
    super.dispose();
  }

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
      _statusMessage = 'Pumili ng kanta para simulan.';
    });
  }

  /// Nagpapadala ng audio gamit ang Multipart Request (iwas HTTP 413 Payload Too Large)
  Future<void> _processAudio() async {
    if (_inputFilePath == null) return;

    String baseUrl = _apiUrlController.text.trim();
    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }
    // Alisin kung may nakakabit na /api/predict para malinis ang base URL
    baseUrl = baseUrl.replaceAll('/api/predict', '');

    setState(() {
      _isProcessing = true;
      _vocalOutputPath = null;
      _musicOutputPath = null;
      _statusMessage = 'Ina-upload ang audio file sa server (Multipart)...';
    });

    try {
      // HAKBANG 1: I-upload ang file gamit ang MultipartRequest sa /upload (Gradio standard)
      // Kung custom API endpoint ang gamit mo (hal. /separate), palitan ang Uri.parse('$baseUrl/upload')
      final uploadUri = Uri.parse('$baseUrl/upload');
      final request = http.MultipartRequest('POST', uploadUri);
      request.files.add(
        await http.MultipartFile.fromPath(
          'files', // Field name para sa Gradio; palitan ng 'file' kung FastAPI/Flask
          _inputFilePath!,
          filename: _inputFileName,
        ),
      );

      final streamedResponse = await request.send().timeout(const Duration(minutes: 3));
      final uploadResponse = await http.Response.fromStream(streamedResponse);

      if (uploadResponse.statusCode != 200) {
        setState(() {
          _isProcessing = false;
          _statusMessage =
              'Nabigo ang upload (HTTP ${uploadResponse.statusCode}). Suriin ang API URL.';
        });
        return;
      }

      // Kunin ang uploaded server file path mula sa response
      final uploadedData = jsonDecode(uploadResponse.body);
      final String serverFilePath = uploadedData is List
          ? uploadedData.first.toString()
          : (uploadedData['path'] ?? uploadedData['url'] ?? '').toString();

      setState(() {
        _statusMessage = 'Pinoproseso ng AI ang paghihiwalay ng Vocals at Minus One...';
      });

      // HAKBANG 2: I-trigger ang AI prediction gamit ang file reference (magaan na JSON payload)
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
          _statusMessage = 'Matagumpay na nahiwalay ang boses at musika!';
        });
      } else {
        setState(() {
          _isProcessing = false;
          _statusMessage =
              'Error sa AI server (HTTP ${predictResponse.statusCode}). Subukan ulit.';
        });
      }
    } on TimeoutException {
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Nag-timeout ang server. Masyadong mahaba ang kanta o busy ang AI.';
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Nabigo ang koneksyon: Siguraduhing active ang iyong Space URL.';
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
      // Gradio relative file path
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
          content: Text('Na-save sa Downloads: $fileName'),
          backgroundColor: Colors.green.shade700,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error sa pag-save: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Vocal Remover'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(widget.isDarkMode ? Icons.light_mode : Icons.dark_mode),
            onPressed: widget.onToggleTheme,
          ),
          IconButton(
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
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: _apiUrlController,
                        decoration: const InputDecoration(
                          labelText: 'AI Server Base URL (walang /api/predict)',
                          hintText: 'https://username-demucs.hf.space',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _pickAudioFile,
                    icon: const Icon(Icons.audio_file),
                    label: Text(_inputFileName ?? 'Pumili ng Audio File'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: (_inputFilePath == null || _isProcessing) ? null : _processAudio,
                    icon: _isProcessing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high),
                    label: Text(
                      _isProcessing ? 'Pinoproseso...' : 'Ihiwalay ang Vocals at Minus One',
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    child: Text(_statusMessage, textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: 20),
                  if (_musicOutputPath != null)
                    _buildResultCard(
                      title: 'Minus One (Instrumental)',
                      icon: Icons.music_note,
                      filePath: _musicOutputPath!,
                    ),
                  if (_vocalOutputPath != null) ...[
                    const SizedBox(height: 12),
                    _buildResultCard(
                      title: 'Vocals Only',
                      icon: Icons.mic,
                      filePath: _vocalOutputPath!,
                    ),
                  ],
                ],
              ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: const Text(
              'Developed by Renante Fullo',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard({
    required String title,
    required IconData icon,
    required String filePath,
  }) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(icon, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            IconButton.filled(
              icon: const Icon(Icons.download),
              onPressed: () => _saveToDownloads(filePath),
            ),
          ],
        ),
      ),
    );
  }
}
