# 클라우드 접속 안내 (팀원용)

> 관련 문서: [클라우드 계정 구조](./cloud-structure.md) · [작업 기록](./2026-11-03-cloud-setup-log.md)

팀원이 자기 계정으로 AWS와 GCP의 콘솔과 CLI를 쓰는 방법을 설명합니다. 두 클라우드 모두 **장기 키(AWS 액세스 키, GCP 서비스 계정 키)를 쓰지 않습니다.** AWS는 IAM Identity Center(SSO), GCP는 각자의 Google 계정으로 로그인합니다.

---

## 1. 한눈에 보기

| | AWS | GCP |
|---|---|---|
| 로그인 계정 | Identity Center 사용자 (아래 표의 username) | 각자의 Gmail 계정 |
| 처음 할 일 | 포털에서 이메일 OTP로 비밀번호 정하기 | 없음 (권한이 이미 부여되어 있음) |
| 쓸 수 있는 곳 | 계정 `platform`, `prod`, `sandbox` | 프로젝트 `sbh26-prod`, `sbh26-sandbox` |
| 권한 | `AdministratorAccess` | Editor |
| 리전 | 서울 `ap-northeast-2`만 허용 | 서울 `asia-northeast3`만 허용 |
| CLI | AWS CLI v2 | gcloud |

| 이름 | AWS username | GCP 계정 |
|---|---|---|
| 이소울 | `soul.lee` | 개인 Gmail (Owner) |
| 박승철 | `seungcheol.park` | 개인 Gmail |
| 김민서 | `minseo.kim` | 개인 Gmail |
| 이상헌 | `sangheon.lee` | 개인 Gmail |

계정과 권한은 Terraform(`infra/org`, `infra/gcp-org`)으로 관리합니다. 바꿀 일이 있으면 이소울에게 요청합니다.

---

## 2. AWS

### 2.1 계정 구조

```
관리 계정            조직, 결제, Identity Center. 팀원은 접근하지 않음
├── platform        플랫폼 백엔드, 대시보드, Executor
├── prod            이전할 원본 프로덕션 (env: aws-prod)
└── sandbox         AI 에이전트가 시험하는 곳 (env: aws-sandbox)
```

| 계정 | 계정 ID | CLI 프로필 |
|---|---|---|
| `platform` | `367123691646` | `platform` |
| `prod` | `714066696240` | `prod` |
| `sandbox` | `608379566120` | `sandbox` |

### 2.2 처음 로그인

AWS는 초대 메일을 보내지 않습니다. 아래 순서대로 직접 로그인하면 됩니다.

1. 접속 포털 https://d-9b675f5a54.awsapps.com/start 에 들어가서 내 username(1절 표)을 입력합니다.
2. 등록된 이메일로 인증 코드(OTP)가 옵니다. 코드를 입력하고 비밀번호를 정합니다.
3. 포털에 `platform`, `prod`, `sandbox` 계정이 보이면 성공입니다. 콘솔은 계정 옆의 **AdministratorAccess**를 눌러 들어갑니다.

### 2.3 CLI 설정

SSO는 **AWS CLI v2**에서만 동작합니다. `aws --version`으로 버전을 확인합니다.

- macOS: `brew install awscli`
- Windows: `winget install Amazon.AWSCLI`
- Linux, WSL: [설치 안내](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)

`~/.aws/config`에 아래 내용을 추가합니다.

```ini
[sso-session sbh26]
sso_start_url = https://d-9b675f5a54.awsapps.com/start
sso_region = ap-northeast-2
sso_registration_scopes = sso:account:access

[profile platform]
sso_session = sbh26
sso_account_id = 367123691646
sso_role_name = AdministratorAccess
region = ap-northeast-2
output = json

[profile prod]
sso_session = sbh26
sso_account_id = 714066696240
sso_role_name = AdministratorAccess
region = ap-northeast-2
output = json

[profile sandbox]
sso_session = sbh26
sso_account_id = 608379566120
sso_role_name = AdministratorAccess
region = ap-northeast-2
output = json
```

로그인하고 확인합니다.

```bash
aws sso login --sso-session sbh26
aws sts get-caller-identity --profile prod
```

`Arn`이 `arn:aws:sts::714066696240:assumed-role/AWSReservedSSO_AdministratorAccess_.../<내 username>` 형식이면 설정이 끝난 것입니다.

### 2.4 매일 쓰기

```bash
aws sso login --sso-session sbh26     # 세션 만료(8시간) 후 다시 로그인

export AWS_PROFILE=prod               # bash, zsh에서 매번 --profile을 붙이지 않으려면
$env:AWS_PROFILE = "prod"             # PowerShell
```

Terraform과 다른 도구도 같은 프로필을 그대로 씁니다.

### 2.5 규칙

SCP(조직 정책)로 막혀 있어서 아래 작업은 권한과 관계없이 거부됩니다.

- 서울(`ap-northeast-2`) 외 리전 사용 (IAM, Route53, CloudFront 같은 글로벌 서비스는 예외)
- IAM 사용자, 액세스 키, 콘솔 비밀번호 생성
- 조직 탈퇴와 계정 해지
- 허용 목록 밖의 EC2 인스턴스 유형과 RDS 클래스
  - 모든 계정: `t3.*`, `t3a.*`, `t4g.*`, `m6i.large`, `m7i.large`, `c6i.large` / `db.t3.*`, `db.t4g.*`
  - `sandbox` 계정: `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`만 허용하고, EKS 클러스터, RDS, NAT Gateway, 로드 밸런서 생성을 막음

그 밖의 규칙은 다음과 같습니다.

- **자격 증명을 공유하지 않습니다.** 토큰이나 `~/.aws/sso/cache`의 내용을 채팅과 저장소에 올리지 않습니다.
- **비용을 확인합니다.** 계정별 월 예산(platform $50, prod $100, sandbox $30)을 넘으면 알림이 갑니다. 쓰지 않는 리소스는 끄거나 지웁니다.

### 2.6 문제 해결

| 증상 | 해결 |
|---|---|
| `You are required to provide multi-factor authentication (MFA) that you do not have.` | 관리자 설정 문제입니다. 이소울에게 알려 주세요 |
| `Error loading SSO Token` 또는 `Token has expired` | `aws sso login --sso-session sbh26` |
| `aws configure sso`나 `--sso-session`을 모르는 명령이라고 나옴 | CLI v1입니다. v2로 다시 설치합니다 |
| 포털에 계정이 보이지 않음 | 권한 할당 전입니다. 이소울에게 요청합니다 |
| `... with an explicit deny in a service control policy` | SCP에 막힌 것입니다. 리전과 인스턴스 유형을 2.5절과 비교해 봅니다 |
| 브라우저가 열리지 않음 (WSL, 원격 서버) | `aws sso login --sso-session sbh26 --use-device-code`로 실행하고, 출력된 URL과 코드를 브라우저에 입력합니다 |

---

## 3. GCP

### 3.1 프로젝트 구조

```
조직 soulee.dev
├── 폴더 prod       └── 프로젝트 sbh26-prod      이전 대상 프로덕션 (env: gcp-prod)
└── 폴더 sandbox    └── 프로젝트 sbh26-sandbox   AI 에이전트가 시험하는 곳 (env: gcp-sandbox)
```

### 3.2 콘솔

https://console.cloud.google.com 에 각자의 Gmail 계정으로 로그인합니다. 상단의 프로젝트 선택 메뉴에서 `sbh26-prod`와 `sbh26-sandbox`가 보이면 됩니다. 권한이 이미 부여되어 있으므로 초대를 수락하는 단계는 없습니다.

프로젝트가 보이지 않으면 프로젝트 선택 메뉴의 **모두** 탭에서 `soulee.dev` 조직을 선택합니다.

### 3.3 CLI 설정

gcloud가 없으면 설치합니다.

- macOS: `brew install --cask gcloud-cli`
- Windows: `winget install Google.CloudSDK`
- Linux, WSL: [설치 안내](https://cloud.google.com/sdk/docs/install)

개인 프로젝트와 섞이지 않도록 **gcloud 설정(configuration)을 따로 만드는 것을 권장합니다.**

```bash
gcloud config configurations create sbh26
gcloud auth login                              # 브라우저에서 내 Gmail 계정으로 로그인
gcloud config set project sbh26-prod
gcloud config set compute/region asia-northeast3
gcloud auth application-default login          # Terraform과 SDK가 쓸 자격 증명
```

확인합니다.

```bash
gcloud projects describe sbh26-prod --format='value(projectId,lifecycleState)'
# sbh26-prod  ACTIVE 이면 설정이 끝난 것입니다
```

### 3.4 매일 쓰기

```bash
gcloud config configurations activate sbh26    # 이 프로젝트 작업을 시작할 때
gcloud config configurations activate default  # 개인 작업으로 돌아갈 때

gcloud config set project sbh26-sandbox        # sandbox 프로젝트로 전환
```

### 3.5 규칙

조직 정책으로 막혀 있어서 아래 작업은 거부됩니다.

- 서울(`asia-northeast3`) 외 위치에 리소스 생성 (예산, IAM 같은 전역 리소스는 예외)
- 서비스 계정 키 생성과 업로드. CI나 플랫폼은 Workload Identity Federation을 씁니다

그 밖의 규칙은 다음과 같습니다.

- **자격 증명을 공유하지 않습니다.** `~/.config/gcloud`의 내용이나 토큰을 채팅과 저장소에 올리지 않습니다.
- **Editor 권한으로는 IAM을 바꿀 수 없습니다.** 권한이 필요하면 이소울에게 요청합니다.
- **비용을 확인합니다.** 월 예산은 prod 10만 원, sandbox 3만 원입니다. 쓰지 않는 VM은 끄거나 지웁니다.
- **기본 VPC가 없습니다.** 네트워크는 Terraform으로 직접 만들어야 합니다.

### 3.6 문제 해결

| 증상 | 해결 |
|---|---|
| `PERMISSION_DENIED` | 다른 Google 계정으로 로그인했을 수 있습니다. `gcloud auth list`로 활성 계정을 확인합니다 |
| `violates constraint 'constraints/gcp.resourceLocations'` | 서울 외 위치를 지정한 것입니다. `asia-northeast3`로 바꿉니다 |
| `API ... has not been used in project` | 켜지 않은 API입니다. 이소울에게 요청합니다 |
| Terraform이 `could not find default credentials` | `gcloud auth application-default login` |
| 리소스가 다른 프로젝트에 생김 | `gcloud config get-value project`로 현재 프로젝트를 확인합니다 |
