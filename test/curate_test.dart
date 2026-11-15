import 'package:flutter_test/flutter_test.dart';
import 'package:toneup_read/models/models.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/curate_service.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/llm_service.dart';

class _FakeLlm extends LlmService {
  final dynamic response;

  /// 记录本次调用透传的 model，用于断言精选确实走了分析模型。
  String? lastModel;
  _FakeLlm(this.response) : super(HttpService(), AppConfigService());

  @override
  Future<dynamic> structured(String system, String user, {String? model, double temperature = 0.3}) async {
    lastModel = model;
    return response;
  }
}

void main() {
  test('模型没返回段落时，精选结果应为空（不能把原文当作精选版保存）', () async {
    final blocks = [ArticleBlock(type: 'p', text: 'one'), ArticleBlock(type: 'p', text: 'two')];
    final res = await CurateService(_FakeLlm(<dynamic>[])).curate(blocks);
    expect(res, isEmpty);
  });

  test('模型正常返回段落时按其重建', () async {
    final blocks = [ArticleBlock(type: 'p', text: 'one long paragraph')];
    final llm = _FakeLlm(['short one', 'short two']);
    final res = await CurateService(llm).curate(blocks);
    expect(res.length, 2);
    expect(res.first.text, 'short one');
    expect(llm.lastModel, AppConfigService.defaultGatewayAnalysisModel,
        reason: '默认的混元 MT 会把正文整段译成中文，精选必须用分析模型');
  });
}
