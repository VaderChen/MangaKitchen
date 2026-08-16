# 만화 주방（MangaKitchen）

[繁體中文](README.md) | [English](README.en.md) | [日本語](README.ja.md) | 한국어

만화 주방(MangaKitchen)은 macOS 네이티브 만화 번역 작업 공간입니다. 프런트엔드는 HTML + JavaScript로 유지하고, Swift Package 백엔드는 도메인 코어, Metal/Core ML Runtime, WKWebView App의 세 계층으로 분리합니다. 코어는 특정 UI 레이아웃에 종속되지 않고 모델 경계, 페이지별 워크플로, 대화 영역, 마스크 및 조판을 처리합니다.

## 저작권 및 적법한 사용

MangaKitchen으로 가져오는 만화 원고, 등장인물, 문구, 그림, 상표 및 기타 콘텐츠의 저작권과 관련 권리는 원작자, 출판사, 정식 라이선스 플랫폼 및 각 적법한 권리자에게 있습니다. 이 도구를 사용한다고 해서 해당 권리가 이전되거나 작품의 복제, 번역, 공개 전송, 배포 또는 판매 권한이 부여되는 것은 아닙니다.

MangaKitchen은 정식 허가를 받은 번역가, 현지화 팀 및 기타 적법한 사용자가 페이지, 마스크, 번역문, 용어 및 조판 과정을 효율적으로 관리하고 반복 작업을 줄여 독자에게 더 빠르고 품질 높은 정식 번역을 제공하도록 돕기 위한 도구입니다. 번역 결과는 2차적 저작물에 해당할 수 있습니다. 원고나 번역 결과를 공개, 공유 또는 배포하기 전에 필요한 허가를 받고 관련 법률, 콘텐츠 라이선스 및 사용하는 모델이나 AI 서비스의 약관을 준수하세요.

MangaKitchen을 해적판, 무단 번역·스캔본, 크랙된 콘텐츠를 제작하거나 배포하는 데 사용하거나 DRM, 워터마크 및 기타 권리 보호 조치를 우회하는 데 사용하지 마세요. 개발자는 저작권 침해를 장려하거나 지원하지 않습니다. 정식 단행본, 전자책, 구독 서비스 및 라이선스 상품을 합법적인 경로로 구매하여 작가, 번역가, 출판사와 창작 생태계를 지원해 주세요.

## 소프트웨어 라이선스

MangaKitchen은 듀얼 라이선스 방식을 사용합니다. 이 repository에서 MangaKitchen 저작권자가 소유하고 별도 표시가 없는 코드는 기본적으로 [GNU General Public License version 3 only](LICENSE)(`GPL-3.0-only`)로 제공됩니다. 비공개 소스 제품 통합, 독점 배포 또는 다른 계약 조건이 필요한 경우 별도의 [상업용 라이선스](COMMERCIAL-LICENSE.md)를 협의할 수 있습니다.

GPLv3 자체도 상업적 사용과 유료 배포를 허용하지만 소스 코드 제공 및 copyleft 의무를 준수해야 합니다. 상업용 라이선스는 대안이며 GPLv3로 이미 받은 권리를 제한하지 않습니다. 타사 package, 모델과 weight, 글꼴 및 만화 콘텐츠는 MangaKitchen 듀얼 라이선스 대상이 아니며 각각의 조건을 따릅니다.

## 구현된 기능

- macOS 14 이상 SwiftUI / WKWebView 애플리케이션 셸.
- HTML/JavaScript와 Swift 사이의 비동기 JSON Bridge.
- `AUTO`, 번체 중국어, 영어, 일본어, 한국어 Web UI. AUTO는 macOS 언어를 따르고 수동 선택은 다음 실행에도 유지되며 네이티브 패널과 MCP 메뉴 막대에도 적용됩니다.
- 일반, 고급, 모델, MCP, 정보 탭으로 구성된 전역 설정 DLG. 언어, 색상 모드, 데이터 위치, 두 모델 경로, MCP 포트 및 IP/CIDR 허용 목록을 설정할 수 있습니다.
- 원본 폴더마다 독립 프로젝트를 만들고 여러 프로젝트를 저장하고 전환할 수 있습니다.
- 하위 폴더 상대 경로를 보존하는 재귀 스캔, 자연 정렬 및 같은 이름의 파일 충돌 방지.
- Command／Shift 다중 선택, 검색, 상태 필터, 선택 페이지의 마스크·번역·합성 일괄 처리.
- 단일 순차 배치 큐, 현재 페이지, 성공／실패 수, 취소, 기록 정리 및 실패 페이지 재시도.
- 프로젝트별 다국어 용어집. 한 원문 용어에 여러 BCP-47 번역을 저장하고 현재 대상 언어에 맞게 자동 선택합니다.
- 4단계 워크플로: 스캔, 텍스트／마스크, 번역／조판 설정, 배경 복원／합성. 전체 페이지 및 모든 페이지 일괄 실행도 지원합니다.
- 이미지마다 버전이 지정된 `.str` JSON을 만들고 텍스트, 위치, 글꼴, 고정／자동 크기 및 마스크 스트로크를 저장합니다.
- 정규화 벡터 브러시로 마스크 추가, 지우기, 영역별 실행 취소 후 이진 PNG를 생성합니다.
- Vision OCR, 가로／세로 텍스트 줄 병합 및 만화 읽기 순서 정렬.
- 이미지→텍스트 모델용 페이지 문맥 프롬프트와 엄격한 JSON 응답 분석.
- Apple Silicon／Metal에서 `mlx-swift-lm`을 사용하는 로컬 Hugging Face MLX VLM 로드.
- model manifest를 사용한 `.mlmodelc`, `.mlmodel`, `.mlpackage` 로드와 Metal GPU용 Core ML 설정.
- 대화 텍스트 마스크와 이미지→이미지 복원. 이미지 모델이 없으면 Metal Compute 인접 복원을 사용합니다.
- Core Text 자동 축소, 가로／세로 조판 및 수동 수정 후 재배치.
- 임의 파일을 노출하지 않고 제한된 사용자 정의 URL Scheme로 원본／출력 이미지를 Web UI에 제공합니다.
- 프로젝트 색인과 상태를 버전 JSON으로 자동 저장하고 쓰기 전 이전 버전을 `.bak`으로 보존한 뒤 시작 시 검증하여 복원합니다.
- 선택 사항인 macOS 26 Swift/MLX Qwen Image Edit worker. 마스크를 모델 조건과 최종 합성 범위에 모두 사용합니다.
- 4단계 tools, workspace／이미지 resources, 취소 및 진행 알림을 제공하는 표준 MCP Streamable HTTP server.
- MCP 활성화 시 macOS 메뉴 막대에 상주하며 메인 창을 닫은 뒤에도 다시 열 수 있습니다.

## 두 가지 사용 방식, 하나의 프로젝트와 4단계 워크플로

MangaKitchen에는 두 가지 사용 방식이 있습니다. 추론과 작업 편성을 누가 담당하는지만 다르며 데이터 형식이나 처리 흐름은 동일합니다. 모든 작업은 원본 폴더 프로젝트에서 시작하고 페이지, 마스크, 번역, 조판 설정, 용어집 및 출력 상태는 해당 프로젝트 범위에 저장됩니다.

공통 4단계는 다음과 같습니다.

1. **프로젝트와 페이지**: 원본 폴더를 선택하고 이미지를 재귀 스캔하여 다중 선택 및 일괄 처리 가능한 페이지 목록을 만듭니다.
2. **텍스트와 마스크**: 대화 영역과 원문을 감지하고 마스크를 생성한 뒤 사용자 또는 Agent가 추가, 삭제, 수정합니다.
3. **번역과 조판**: 각 영역의 원문, 번역문, 위치, 글꼴 및 크기를 이미지의 `.str` 파일에 기록합니다.
4. **복원과 합성**: 원래 글자를 제거하고 배경을 복원한 뒤 번역문을 조판하여 프로젝트 출력 폴더에 저장합니다.

4단계는 재개 가능한 상태, 산출물 및 의존 관계를 정의하며 매번 1단계부터 다시 실행하는 고정 체크리스트가 아닙니다. GUI와 MCP는 페이지 상태와 `.str`을 먼저 확인하고 선행 자료가 있는 임의 단계부터 시작할 수 있습니다. 마스크가 있으면 바로 번역하고, 번역문이 있으면 바로 조판 또는 합성하며, 한 영역만 수정할 수도 있습니다. 사용자나 Agent가 명시적으로 재실행하지 않는 한 완료된 OCR, 마스크, 번역문 및 수동 편집을 덮어쓰지 않습니다.

임의 단계에서 시작하기 전에 상태 이름뿐 아니라 페이지별 실제 자료를 검사해야 합니다. 요청 단계에 필요한 산출물이 없으면 가장 가까운 필수 작업을 찾을 때까지 한 단계씩 되돌아갑니다.

- 4단계 전에 유효한 마스크와 `.str` 번역／조판 자료를 확인합니다. 번역문이 없으면 3단계로, 텍스트 영역 또는 마스크가 없으면 다시 2단계로 돌아갑니다.
- 3단계 전에 원본 페이지, 텍스트 영역, OCR 원문 및 마스크를 확인합니다. 불완전하면 2단계로 돌아갑니다.
- 2단계 전에 원본 이미지가 존재하고 프로젝트 페이지 색인이 유효한지 확인합니다. 누락되면 1단계에서 다시 스캔합니다.
- 되돌리기는 누락되거나 무효한 산출물만 보충합니다. 유효한 선행 자료는 다시 만들지 않으며 페이지마다 다른 단계에서 재개할 수 있습니다.

### 방식 A: 모델을 다운로드하여 완전한 오프라인으로 실행

“설정 → 모델”에서 이미지→텍스트 모델과 선택적인 이미지→이미지 모델을 지정합니다. OCR, 번역, 배경 복원 및 합성은 Mac에서 실행됩니다. 모델 다운로드 후 만화 내용을 외부 AI 서비스로 보낼 필요가 없습니다.

- `imageToText` 모델은 3단계 페이지 문맥 번역을 담당하며 전체 페이지 자동 처리에 필요합니다.
- `imageToImage` 모델은 4단계 배경 복원을 담당하는 선택 사항입니다. 설정하지 않으면 Metal Compute 대체 복원을 사용합니다.
- GUI에서 각 단계를 따로 실행하거나 “선택／모든 페이지 전체 처리”를 사용할 수 있습니다. 원클릭 처리도 내부적으로 2~4단계를 순서대로 실행하고 중간 자료를 보존합니다.
- 결과는 프로젝트와 `.str`에 기록되므로 임의 단계를 수정한 후 뒤 단계만 다시 실행할 수 있습니다.

### 방식 B: AI Agent가 MCP를 통해 실행

“설정 → MCP”에서 서비스를 활성화하고 포트와 클라이언트 IP/CIDR 허용 목록을 설정한 뒤 Streamable HTTP를 지원하는 AI Agent를 연결합니다. Agent도 workspace／project 상태와 4단계 산출물을 사용하지만 기존 자료가 있으면 임의 단계부터 재개하여 완료된 작업을 반복하지 않습니다.

로컬 이미지→텍스트 모델 없이 새 프로젝트를 번역하는 예:

1. `mangakitchen.workspace.open`을 호출하고 반환된 `workspace_id`를 유지합니다.
2. `mangakitchen.page.detect_masks`로 OCR과 마스크 생성을 수행합니다.
3. 페이지, 원본 이미지 또는 `.str` resource를 읽고 Agent가 번역한 뒤 `mangakitchen.region.update`로 각 영역의 번역문과 조판 설정을 기록합니다.
4. `mangakitchen.page.compose`로 배경 복원과 출력을 수행합니다.

로컬 `imageToText` 모델도 로드되어 있으면 Agent가 `mangakitchen.page.translate` 또는 `mangakitchen.page.run_full`을 사용할 수 있습니다. `page.run_full`에는 로컬 이미지→텍스트 모델이 필요합니다. 순수 Agent 번역은 `detect_masks → region.update → compose`를 사용합니다.

기존 프로젝트에서는 Agent가 workspace, page, `.str` resource와 실제 산출물을 먼저 검사한 뒤 필요한 tool만 호출합니다. 유효한 마스크가 있는 `maskReady` 페이지는 번역 또는 `region.update`부터, 완전한 번역문이 있는 `translationReady` 페이지는 `compose`부터 시작할 수 있습니다. 자료가 누락되면 위 규칙에 따라 단계별로 되돌아갑니다. 순수 Agent 모드에서 3단계로 돌아갈 때는 로컬 모델을 강제하지 않고 Agent가 번역하여 `region.update`에 기록합니다.

MCP 모드는 여러 workspace, 명시적인 `workspace_id`, 다중 페이지 배치, 프로젝트 용어집, 취소 및 진행 알림도 지원합니다. AI Agent는 워크플로 작업자이며 별도 저장 백엔드가 아닙니다.

## 실행

```bash
swift build
swift run MangaKitchen
```

GUI와 함께 MCP server를 시작하려면:

```bash
swift run MangaKitchen --mcp=on
```

GUI는 항상 시작됩니다. `--mcp`를 생략하면 저장된 설정을 사용하고 `--mcp=on|off`는 이번 실행만 재정의합니다. listener는 `0.0.0.0`에 bind하고 기본 포트는 `12080`이며 허용 목록에 포함된 실제 원본 IP/CIDR의 request만 받습니다. 기본 허용 목록은 `127.0.0.1`뿐입니다. 로컬 endpoint는 `http://127.0.0.1:12080/mcp`이고 `--mcp-port=<port>`로 이번 실행 포트를 바꿀 수 있습니다. 메인 창을 닫아도 App은 종료되지 않으며 메뉴 막대에서 다시 열 수 있습니다.

데이터 저장 위치 변경은 다시 시작한 뒤 적용됩니다. 두 모델 변경은 즉시 적용되며 MCP 스위치, 포트 또는 허용 목록 변경 시 listener를 재시작합니다.

기본 데이터 저장 위치:

```text
~/Library/Application Support/MangaKitchen/
  Projects/library.json
  Projects/<project-uuid>/project.json
  Projects/<project-uuid>/StringTables/
  Artifacts/<page-uuid>/
```

이전 `Workspace/workspace.json`은 첫 실행 시 첫 번째 프로젝트로 이전되며 원본 파일은 유지됩니다.

## 모델 형식

모델 폴더에는 `mangakitchen-model.json`이 있어야 합니다. 예:

- `Examples/Models/ImageToTextModel/mangakitchen-model.json`
- `Examples/Models/ImageToImageModel/mangakitchen-model.json`
- `Examples/Models/MLXVLMModel/mangakitchen-model.json`
- `Examples/Models/QwenImageEditModel/mangakitchen-model.json`

manifest feature 이름은 실제 Core ML 모델과 일치해야 합니다. 현재 Adapter는 이미지→텍스트의 이미지／선택 prompt／문자열 출력과 이미지→이미지의 이미지／선택 mask·prompt／이미지 출력을 지원합니다.

Core ML manifest는 한 번의 prediction으로 패키징된 모델용 일반 Adapter입니다. tokenizer와 순차 decode가 필요한 Qwen-VL은 전용 MLX Adapter를 사용하고 sampler loop가 있는 diffusion model도 전용 `ImageToImageGenerating` Adapter가 필요합니다. 코어 pipeline은 변경하지 않습니다.

`MLXVLMRuntime`은 `mlx-swift-lm`이 지원하는 `model_type`의 로컬 VLM을 불러올 수 있습니다. 약 3GB인 `lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit`부터 시작하는 것을 권장합니다.

1. Hugging Face 모델 전체를 로컬 폴더에 다운로드합니다.
2. `Examples/Models/MLXVLMModel/mangakitchen-model.json`을 모델 루트에 복사합니다.
3. App에서 해당 폴더를 선택합니다. 첫 로드 후 container를 메모리에 유지하여 페이지 간 재사용합니다.

단일 safetensors 파일만으로는 충분하지 않습니다. `config.json`, tokenizer, processor 및 chat template를 함께 보존해야 합니다.

## Qwen Image Edit Worker

이미지→이미지 추론은 별도 Swift Package에서 실행하여 완료 또는 취소 후 대형 모델을 완전히 해제합니다. 현재 macOS 26이 필요합니다.

```bash
Scripts/build-qwen-image-edit-worker.sh
```

개발 빌드 검색 위치:

```text
RuntimeSupport/QwenImageEditWorker/.build/release/MangaKitchenQwenImageEditWorker
```

배포용 `.app`은 이를 `Contents/Helpers/`에 복사해야 합니다. `MANGAKITCHEN_QWEN_WORKER`로 절대 경로를 지정할 수도 있습니다.

```text
QwenImageEditModel/
  mangakitchen-model.json
  snapshot/
    vae/
    text_encoder/
    processor/
    transformer/
  quantized/
    qie-2511-dit-int4-mod8.safetensors
    qie-2511-vl7b-int4.safetensors
```

`snapshot`은 Qwen Image Edit 2511 기본 모델이며 두 INT4 파일은 Swift Runtime용 사전 양자화 모델입니다. Worker는 원본 이미지와 이진 mask를 받고 생성 후 mask 내부 픽셀만 사용합니다.

## 패키지 계층

```text
MangaKitchenCore       도메인 자료, 좌표, 처리 설정, 모델／워크플로 protocol
MangaKitchenRuntime    Vision OCR, 읽기 순서, Core ML/Metal, 마스크, 복원, Core Text
MangaKitchenApp        SwiftUI, WKWebView, URL Scheme, JSON Bridge, HTML/JavaScript
MangaKitchenApp/MCP    GUI process 안의 MCP Streamable HTTP adapter와 수명 주기
```

설계와 데이터 흐름은 [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md), Swift／JavaScript／MCP 계약은 [Documentation/WORKFLOW_API.md](Documentation/WORKFLOW_API.md)를 참고하세요.

## 알려진 제한

- 모델 weight는 포함하지 않습니다. 정식 모델 선택 후 크기, 라이선스 및 배포 정책을 정해야 합니다.
- OCR 영역은 현재 일반 규칙으로 병합합니다. 말풍선 윤곽, 내레이션 상자 및 효과음은 향후 segmentation으로 개선할 수 있습니다.
- Metal 인접 복원은 대체 수단입니다. 복잡한 망점이나 선화를 가로지르는 글자는 inpainting model을 권장합니다.
- Qwen Image Edit INT4는 약 25GB급 추론 메모리와 페이지마다 전체 diffusion 실행이 필요합니다.
- App Sandbox security-scoped bookmark, 서명, notarization 및 정식 `.app` packaging은 아직 구현되지 않았습니다.
