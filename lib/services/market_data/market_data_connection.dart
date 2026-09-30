typedef WebSocketFactory = Stream<dynamic> Function(Uri uri);

class MarketDataConnection {
  const MarketDataConnection({
    required this.uri,
    required this.streamFactory,
  });

  final Uri uri;
  final WebSocketFactory streamFactory;

  Stream<dynamic> connect() => streamFactory(uri);
}
