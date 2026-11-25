import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../domain/answer.dart';
import '../domain/config.dart';
import 'app_log.dart';

class SearchHit {
  const SearchHit(this.title, this.url, this.snippet);
  final String title, url, snippet;
  Map<String, String> toJson() => {
    'title': title,
    'url': url,
    'snippet': snippet,
  };
}

class QuestionSearchResult {
  const QuestionSearchResult(this.hits, {this.calls = 0});
  final List<SearchHit> hits;
  final int calls;
}

// Independent of hosted model tools: even a model without search can verify a
// question. Only search snippets are read; result URLs are never fetched here.
class QuestionSearch {
  QuestionSearch({this.log, this.searchEndpoint});
  AppLog? log;
  final Uri? searchEndpoint;
  final Set<HttpClient> _clients = {};
  int _generation = 0;

  void cancelAll() {
    _generation++;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }

  Future<QuestionSearchResult> search(
    Question question,
    Duration budget,
  ) async {
    final generation = _generation;
    final watch = Stopwatch()..start();
    final title = question.title.replaceAll(RegExp(r'\s+'), ' ').trim();
    final boundedTitle = title.length > 700 ? title.substring(0, 700) : title;
    final similar = boundedTitle
        .replaceAll(RegExp(r'[，。！？、；：,.!?;:（）()“”"\[\]{}]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final queries = ['"$boundedTitle" 答案', '$similar 题库 答案'];
    final hits = <String, SearchHit>{};
    var calls = 0;
    for (var index = 0; index < queries.length; index++) {
      if (generation != _generation) throw StateError('搜索已取消');
      final remaining = budget - watch.elapsed;
      if (remaining <= Duration.zero) break;
      // Leave time for the similar-question query if the exact query stalls.
      final timeout = remaining ~/ (queries.length - index);
      final uri = (searchEndpoint ?? Uri.https('www.bing.com', '/search'))
          .replace(queryParameters: {'format': 'rss', 'q': queries[index]});
      final client = HttpClient()..connectionTimeout = timeout;
      _clients.add(client);
      final requestId = newId();
      final requestWatch = Stopwatch()..start();
      final bytes = <int>[];
      var chunks = 0;
      log?.write('network', 'question.search.start', {
        'requestId': requestId,
        'method': 'GET',
        'url': uri.toString(),
        'queryKind': index == 0 ? 'exact' : 'similar',
        'timeoutMs': timeout.inMilliseconds,
      });
      try {
        final found = await (() async {
          final request = await client.getUrl(uri);
          request.headers.set(
            HttpHeaders.acceptHeader,
            'application/rss+xml, application/xml',
          );
          log?.write('network', 'question.search.request.ready', {
            'requestId': requestId,
            'headers': logHeaders(request.headers),
            'connection': logConnection(request.connectionInfo),
            'elapsedMs': requestWatch.elapsedMilliseconds,
          });
          final response = await request.close();
          log?.write('network', 'question.search.response.headers', {
            'requestId': requestId,
            'elapsedMs': requestWatch.elapsedMilliseconds,
            ...logResponseMetadata(response),
          });
          await for (final chunk in response) {
            log?.write('network', 'question.search.response.chunk', {
              'requestId': requestId,
              'index': chunks,
              'elapsedMs': requestWatch.elapsedMilliseconds,
              'body': logBytes(chunk),
            });
            chunks++;
            bytes.addAll(chunk);
            if (bytes.length > 1024 * 1024) {
              throw const FormatException('搜索响应过大');
            }
          }
          log?.write('network', 'question.search.response', {
            'requestId': requestId,
            'status': response.statusCode,
            'headers': logHeaders(response.headers),
            'elapsedMs': requestWatch.elapsedMilliseconds,
            'chunks': chunks,
            'body': logBytes(bytes),
          });
          if (response.statusCode != 200) {
            throw HttpException('搜索 HTTP ${response.statusCode}');
          }
          return parseSearchFeed(utf8.decode(bytes));
        })().timeout(timeout);
        calls++;
        for (final hit in found.take(5)) {
          hits[hit.url] = hit;
        }
      } catch (error, stack) {
        log?.error('question.search.error', error, stack, {
          'requestId': requestId,
          'elapsedMs': requestWatch.elapsedMilliseconds,
          'receivedBytes': bytes.length,
          'chunks': chunks,
        });
        if (generation != _generation) rethrow;
      } finally {
        client.close(force: true);
        _clients.remove(client);
      }
    }
    if (generation != _generation) throw StateError('搜索已取消');
    return QuestionSearchResult(hits.values.toList(), calls: calls);
  }
}

List<SearchHit> parseSearchFeed(String raw) {
  final document = XmlDocument.parse(raw);
  if (document.rootElement.name.local != 'rss') {
    throw const FormatException('搜索未返回 RSS 结果');
  }
  String clean(String text) => text.replaceAll(RegExp(r'<[^>]*>'), ' ').trim();
  String bounded(String text) =>
      text.length > 1500 ? text.substring(0, 1500) : text;
  return document
      .findAllElements('item')
      .map((item) {
        String field(String name) => item.getElement(name)?.innerText ?? '';
        return SearchHit(
          bounded(clean(field('title'))),
          field('link').trim(),
          bounded(clean(field('description'))),
        );
      })
      .where((hit) {
        final uri = Uri.tryParse(hit.url);
        return hit.title.isNotEmpty &&
            uri != null &&
            ['https', 'http'].contains(uri.scheme) &&
            uri.hasAuthority &&
            uri.userInfo.isEmpty;
      })
      .toList();
}
