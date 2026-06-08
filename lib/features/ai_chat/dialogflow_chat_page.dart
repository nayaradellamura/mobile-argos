import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class DialogflowChatPage extends StatefulWidget {
  final String idVistoria;

  const DialogflowChatPage({
    super.key, 
    required this.idVistoria,
  });

  @override
  State<DialogflowChatPage> createState() => _DialogflowChatPageState();
}

class _DialogflowChatPageState extends State<DialogflowChatPage> {
  late final WebViewController controller;

  @override
  void initState() {
    super.initState();
    final htmlContent = '''
<!DOCTYPE html>
<html lang="pt-br">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">

  <link rel="stylesheet" href="https://www.gstatic.com/dialogflow-console/fast/df-messenger/prod/v1/themes/df-messenger-default.css">
  <script src="https://www.gstatic.com/dialogflow-console/fast/df-messenger/prod/v1/df-messenger.js"></script>

  <style>
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background: #F3FBFF;
      overflow: hidden;
      font-family: Arial, sans-serif;
    }

    df-messenger {
      z-index: 999;
      position: fixed;
      --df-messenger-font-color: #1F2937;
      --df-messenger-font-family: Arial, sans-serif;
      --df-messenger-chat-background: #F3FBFF;
      --df-messenger-message-user-background: #D3E3FD;
      --df-messenger-message-bot-background: #FFFFFF;
      --df-messenger-titlebar-background: #0057C0;
      --df-messenger-titlebar-font-color: #FFFFFF;
      bottom: 0;
      right: 0;
      top: 0;
      left: 0;
    }
  </style>
</head>
<body>
  <df-messenger
    location="us-central1"
    project-id="upheld-magpie-404322"
    agent-id="8ece03b0-a71c-4860-818f-422d9c61ddac"
    language-code="pt-br"
    max-query-length="-1">
    <df-messenger-chat chat-title="Argos IA"></df-messenger-chat>
  </df-messenger>

  <script>
    document.addEventListener('DOMContentLoaded', function () {
      const dfMessenger = document.querySelector('df-messenger');
      dfMessenger.addEventListener('df-messenger-loaded', function () {
        dfMessenger.setQueryParameters({
          parameters: {
            "id_vistoria": "${widget.idVistoria}"
          }
        });
      });
    });
  </script>
</body>
</html>
''';

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF3FBFF))
      ..loadHtmlString(htmlContent);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3FBFF),
      body: SafeArea(
        child: WebViewWidget(controller: controller),
      ),
    );
  }
}