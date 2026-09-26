Include %occStatus

/// 内蔵の OAuth 2.0 認可サーバで、SMART v2 の細粒度スコープを試す環境を作る。
/// Build() は docker build の中で、Runtime() は IRIS の起動後に実行する。
Class Demo.Setup
{

/// FHIR リポジトリを置くネームスペース
Parameter NAMESPACE = "FHIRDEMO";

/// FHIR エンドポイントのパス
Parameter FHIRAPPKEY = "/fhir/r4";

/// 発行元（issuer）のホスト名。ブラウザと IRIS の両方から届く値にする
Parameter ISSUERHOST = "localhost";

/// 発行元のポート（Web Gateway が HTTPS を受けるポート）
Parameter ISSUERPORT = 8443;

/// IRIS がクライアントとして HTTPS で通信するときの TLS 設定
Parameter SSLCONFIG = "DemoClientTLS";

/// 認可サーバに登録する分析アプリ（public クライアント）
Parameter APPCLIENT = "smart-demo-app";

/// 認可サーバに登録する FHIR リポジトリ（resource）
Parameter RESOURCECLIENT = "fhir-resource-server";

/// 分析アプリを配信する Web アプリケーションのパス
Parameter APPPATH = "/app";

/// 分析アプリのファイルの置き場所
Parameter APPDIR = "/opt/demo/app/";

/// 分析アプリのリダイレクト URI
Parameter REDIRECTURI = "https://localhost:8443/app/callback.html";

/// ログインに使うデモ用の利用者
Parameter DEMOUSER = "doctor01";

/// デモ用のパスワード（このデモ以外では使わない）
Parameter DEMOPASSWORD = "Doctor01-demo";

/// デモ用の利用者に対応する FHIR リソース（fhirUser クレームの値）
Parameter DEMOFHIRUSER = "Practitioner/pr-001";

/// 認可サーバに登録するスコープ。インストーラが登録するスコープ（user/*.rs や user/*.cud など）は消して、これだけにする
Parameter SCOPES = "openid,profile,fhirUser,launch,launch/patient,offline_access,online_access,user/Patient.rs,user/Condition.rs,user/Observation.rs,user/Observation.rs?category=laboratory,user/Observation.rs?category=vital-signs,user/Observation.rs?category=survey,patient/Observation.rs,patient/Observation.rs?category=laboratory";

/// smart-configuration で公開する SMART on FHIR の機能
Parameter SMARTCAPABILITIES = "launch-standalone, client-public, sso-openid-connect, permission-v2, permission-user, permission-patient";

/// サンプルデータのフォルダ。参照される側（デモの医師、医療機関と医師）から順に読み込む
Parameter DATADIRS = "/opt/demo/data/fhir/0-demo,/opt/demo/data/fhir/1-synthea-org,/opt/demo/data/fhir/2-synthea-patients";

/// fhirUser を入れる検証クラスのソース。認可サーバのカスタマイズ用ネームスペースに読み込む
Parameter CUSTOMIZATIONSRC = "/opt/demo/src/hssys";

/// 認可サーバで使う検証クラス
Parameter VALIDATECLASS = "Demo.OAuth2.Validate";

/// 確認スクリプト向けの設定ファイル（ホストの ./shared。デモ用の資格情報を含む）
Parameter SHAREDFILE = "/shared/demo-config.json";

/// 分析アプリ向けの設定ファイル（ブラウザに配信するので、資格情報は含めない）
Parameter APPCONFIGFILE = "/opt/demo/app/config.json";

ClassMethod BaseURL() As %String
{
	Quit "https://"_..#ISSUERHOST_":"_..#ISSUERPORT
}

ClassMethod IssuerURL() As %String
{
	Quit ..BaseURL()_"/oauth2"
}

/// docker build の中で実行する
ClassMethod Build() As %Status
{
	Set sc = $$$OK
	Try {
		Write !, "[Demo.Setup] Build start", !
		$$$ThrowOnError(..PrepareSecurity())
		$$$ThrowOnError(..CreateFHIRServer())
		$$$ThrowOnError(..LoadSampleData())
		$$$ThrowOnError(..ConfigureOAuthServer())
		$$$ThrowOnError(..RegisterClients())
		$$$ThrowOnError(..CreateAppWebApplication())
		Write "[Demo.Setup] Build done", !
	}
	Catch ex {
		Set sc = ex.AsStatus()
	}
	Quit sc
}

/// IRIS の起動後に実行する（Web Gateway の HTTPS が使えるようになってから）
ClassMethod Runtime() As %Status
{
	Set sc = $$$OK
	Try {
		Write !, "[Demo.Setup] Runtime start", !
		$$$ThrowOnError(..WaitForIssuer())
		$$$ThrowOnError(..ConfigureResourceServer())
		$$$ThrowOnError(..AttachOAuthToFHIR())
		$$$ThrowOnError(..WriteSharedConfig())
		Write "[Demo.Setup] Runtime done. App: ", ..BaseURL(), ..#APPPATH, "/  FHIR: ", ..BaseURL(), ..#FHIRAPPKEY, !
	}
	Catch ex {
		Set sc = ex.AsStatus()
	}
	Quit sc
}

/// パスワードの期限切れを解除し、デモ用の利用者と TLS 設定を作る
ClassMethod PrepareSecurity() As %Status
{
	New $Namespace
	Set $Namespace = "%SYS"
	Set sc = ##class(Security.Users).UnExpireUserPasswords("*")
	Quit:$$$ISERR(sc) sc

	If '##class(Security.Users).Exists(..#DEMOUSER) {
		// Create(Username, UserRoles, Password, FullName, NameSpace, Routine, ExpirationDate, ChangePassword, Enabled, Comment)
		Set sc = ##class(Security.Users).Create(..#DEMOUSER, "", ..#DEMOPASSWORD, "Demo Doctor", "", "", "", 0, 1, "SMART v2 scope demo user")
		Quit:$$$ISERR(sc) sc
	}

	If '##class(Security.SSLConfigs).Exists(..#SSLCONFIG) {
		Set props("Description") = "Client TLS for the demo (self-signed server certificate, no peer verification)"
		Set props("Type") = 0
		Set props("VerifyPeer") = 0
		Set props("Enabled") = 1
		Set sc = ##class(Security.SSLConfigs).Create(..#SSLCONFIG, .props)
		Quit:$$$ISERR(sc) sc
	}
	Quit $$$OK
}

/// ネームスペースと FHIR リポジトリを作る
ClassMethod CreateFHIRServer() As %Status
{
	Set sc = $$$OK
	New $Namespace
	Try {
		If '##class(%SYS.Namespace).Exists(..#NAMESPACE) {
			Set $Namespace = "HSLIB"
			Do ##class(HS.Util.Installer.Foundation).Install(..#NAMESPACE)
		}
		Set $Namespace = ..#NAMESPACE
		Do ##class(HS.FHIRServer.Installer).InstallNamespace()
		If '##class(HS.FHIRServer.ServiceAdmin).EndpointExists(..#FHIRAPPKEY) {
			Do ##class(HS.FHIRServer.Installer).InstallInstance(..#FHIRAPPKEY, "HS.FHIRServer.Storage.JsonAdvSQL.InteractionsStrategy", $ListBuild("hl7.fhir.r4.core@4.0.1"))
		}
		// FHIR サーバのログ（^FSLOG）を有効にする。トークン検証の失敗理由を追えるようにするため。
		// "all" にすると SQL まで記録されてすぐに大きくなるので、メッセージ（Msg）だけにする
		Set ^FSLogChannel("Msg") = 1
		$$$ThrowOnError(..ConfigureEndpoint())
	}
	Catch ex {
		Set sc = ex.AsStatus()
	}
	Quit sc
}

/// FHIR エンドポイントの設定: スコープによる検索結果の絞り込みと、SMART on FHIR の機能
ClassMethod ConfigureEndpoint() As %Status
{
	Set sc = $$$OK
	New $Namespace
	Try {
		$$$ThrowOnError(..SetSearchFiltering(1))

		// smart-configuration が返す SMART on FHIR の機能。未設定だと smart-configuration がエラーになる。
		// この値はサービスの設定ではなく、ストラテジーの設定（smart_capabilities）に入る
		Set $Namespace = ..#NAMESPACE
		Set instanceId = ##class(HS.FHIRServer.ServiceAdmin).GetInstanceIdForEndpoint(..#FHIRAPPKEY)
		Set strategyConfig = ##class(HS.FHIRServer.ServiceAdmin).GetInstanceStrategyConfigData(instanceId)
		Set strategyConfig."smart_capabilities" = ..#SMARTCAPABILITIES
		Do ##class(HS.FHIRServer.ServiceAdmin).SetInstanceStrategyConfigData(instanceId, strategyConfig)
		Write "[Demo.Setup] endpoint: smart_capabilities=", ..#SMARTCAPABILITIES, !
	}
	Catch ex {
		Set sc = ex.AsStatus()
	}
	Quit sc
}

/// サンプルデータ（デモの医師と、Synthea の合成患者データ）を登録する
ClassMethod LoadSampleData() As %Status
{
	Set sc = $$$OK
	New $Namespace
	Set $Namespace = ..#NAMESPACE
	For i=1:1:$Length(..#DATADIRS, ",") {
		Set dir = $Piece(..#DATADIRS, ",", i)
		If '##class(%File).DirectoryExists(dir) Continue
		Write "[Demo.Setup] loading ", dir, !
		Set sc = ##class(HS.FHIRServer.Tools.DataLoader).SubmitResourceFiles(dir, "FHIRServer", ..#FHIRAPPKEY)
		If $$$ISERR(sc) Quit
	}
	Quit sc
}

/// IRIS for Health が SMART on FHIR 向けに用意しているインストーラで、内蔵の認可サーバを作る
ClassMethod ConfigureOAuthServer() As %Status
{
	Set sc = $$$OK
	New $Namespace
	Try {
		Set $Namespace = ..#NAMESPACE
		Set ok = ##class(HS.HC.OAuth2.Server.Installer).ConfigureAuthServer(.issuer, ..#ISSUERHOST, ..#ISSUERPORT, "", 1)
		Write "[Demo.Setup] ConfigureAuthServer ok=", ok, " issuer=", $Get(issuer), !
		If 'ok $$$ThrowStatus($$$ERROR($$$GeneralError, "ConfigureAuthServer failed"))

		Set $Namespace = "%SYS"
		Set server = ##class(OAuth2.Server.Configuration).Open(.sc)
		$$$ThrowOnError(sc)
		If '$IsObject(server) $$$ThrowStatus($$$ERROR($$$GeneralError, "OAuth2.Server.Configuration was not found"))

		// fhirUser を入れる検証クラスを、認可サーバのカスタマイズ用ネームスペース（インストーラの既定は HSSYS）に読み込む
		$$$ThrowOnError(..LoadCustomization(server.CustomizationNamespace))
		Set server.ValidateUserClass = ..#VALIDATECLASS

		// 発行してよいスコープを登録する（細粒度スコープを含む）。インストーラは、すべてのリソースを読める user/*.rs や
		// 書き込みの user/*.cud などのワイルドカードのスコープも登録するので、いったん消して、このデモで使うスコープだけにする
		Do server.SupportedScopes.Clear()
		For i=1:1:$Length(..#SCOPES, ",") {
			Set scope = $Piece(..#SCOPES, ",", i)
			Do server.SupportedScopes.SetAt(scope, scope)
		}
		// 登録したスコープだけを発行する（インストーラの既定と同じ。明示しておく）。
		// オンにすると、登録していないスコープもそのままトークンに入る
		Set server.AllowUnsupportedScope = 0
		// 既定のスコープを空にする。インストーラは user/*.rs を入れるので、アプリがスコープを付け忘れると
		// すべてのリソースを読めるトークンが出る。空にすると、スコープのない要求は invalid_scope で拒否される
		Set server.DefaultScope = ""
		// ブラウザのアプリ（public クライアント）には PKCE を必須にする（インストーラの既定と同じ）
		Set server.ForcePKCEForPublicClients = 1
		$$$ThrowOnError(server.Save())
		Do ..ShowOAuthServer(server)
	}
	Catch ex {
		Set sc = ex.AsStatus()
	}
	Quit sc
}

/// 検証クラスをカスタマイズ用ネームスペースに読み込み、利用者と fhirUser の対応を登録する
ClassMethod LoadCustomization(pNamespace As %String) As %Status
{
	New $Namespace
	Set $Namespace = pNamespace
	Set sc = $system.OBJ.LoadDir(..#CUSTOMIZATIONSRC, "ck", .errors, 1)
	Quit:$$$ISERR(sc) sc
	// デモ用の対応表。実際の運用では、利用者と Practitioner の対応を管理する仕組みから引く
	Set ^Demo.FHIRUser(..#DEMOUSER) = ..#DEMOFHIRUSER
	Write "[Demo.Setup] ", ..#VALIDATECLASS, " loaded into ", pNamespace, " (", ..#DEMOUSER, " -> ", ..#DEMOFHIRUSER, ")", !
	Quit $$$OK
}

/// 認可サーバに、分析アプリと FHIR リポジトリを登録する
ClassMethod RegisterClients() As %Status
{
	Set sc = $$$OK
	New $Namespace
	Set $Namespace = "%SYS"
	Try {
		// 分析アプリ: 秘密を持てない public クライアント。認可コードフローと PKCE を使う
		Set app = ..OpenServerClient(..#APPCLIENT)
		If '$IsObject(app) {
			Set app = ##class(OAuth2.Server.Client).%New()
			Set app.Name = ..#APPCLIENT
		}
		Set app.Description = "SMART v2 scope demo app (public client, authorization code + PKCE)"
		Set app.ClientType = "public"
		Do app.RedirectURL.Clear()
		Do app.RedirectURL.Insert(..#REDIRECTURI)
		Set app.Metadata."grant_types" = $ListBuild("authorization_code", "refresh_token")
		Set app.Metadata."response_types" = $ListBuild("code")
		// IRIS の認可サーバは、public クライアントがトークン交換で client_id を本文に入れて送る方式を
		// client_secret_post として判定する。"none" にすると "Unexpected authentication method" で拒否される
		Set app.Metadata."token_endpoint_auth_method" = "client_secret_post"
		$$$ThrowOnError(app.%Save())

		// FHIR リポジトリ: アクセストークンを確かめる側
		Set rs = ..OpenServerClient(..#RESOURCECLIENT)
		If '$IsObject(rs) {
			Set rs = ##class(OAuth2.Server.Client).%New()
			Set rs.Name = ..#RESOURCECLIENT
		}
		Set rs.Description = "FHIR repository (resource server)"
		Set rs.ClientType = "resource"
		// FHIR リポジトリは、トークンのイントロスペクションを Basic 認証で呼ぶ
		Set rs.Metadata."token_endpoint_auth_method" = "client_secret_basic"
		$$$ThrowOnError(rs.%Save())

		Write "[Demo.Setup] clients: ", ..#APPCLIENT, " client_id=", app.ClientId, " / ", ..#RESOURCECLIENT, " client_id=", rs.ClientId, !
	}
	Catch ex {
		Set sc = ex.AsStatus()
	}
	Quit sc
}

/// 分析アプリ（HTML と JavaScript）を配信する Web アプリケーションを作る
ClassMethod CreateAppWebApplication() As %Status
{
	New $Namespace
	Set $Namespace = "%SYS"
	Set props("Description") = "SMART v2 scope demo app (static files)"
	Set props("Path") = ..#APPDIR
	Set props("NameSpace") = ..#NAMESPACE
	Set props("Enabled") = 1
	// アプリは静的ファイルだけなので、認証なしで配信する。データは FHIR リポジトリがトークンで守る
	Set props("AutheEnabled") = 64
	Set props("ServeFiles") = 1
	Set props("Recurse") = 1
	Set props("CSPZENEnabled") = 0
	If ##class(Security.Applications).Exists(..#APPPATH) {
		Set sc = ##class(Security.Applications).Modify(..#APPPATH, .props)
	}
	Else {
		Set sc = ##class(Security.Applications).Create(..#APPPATH, .props)
	}
	If $$$ISOK(sc) Write "[Demo.Setup] web application: ", ..#APPPATH, " -> ", ..#APPDIR, !
	Quit sc
}

/// 発行元が HTTPS で応答するまで待つ
ClassMethod WaitForIssuer(pTimeoutSec As %Integer = 300) As %Status
{
	Set reachable = 0
	For i=1:1:pTimeoutSec {
		Set req = ##class(%Net.HttpRequest).%New()
		Set req.Server = ..#ISSUERHOST
		Set req.Port = ..#ISSUERPORT
		Set req.Https = 1
		Set req.SSLConfiguration = ..#SSLCONFIG
		Set req.Timeout = 5
		Set st = req.Get("/oauth2/.well-known/openid-configuration")
		If $$$ISOK(st) && (req.HttpResponse.StatusCode = 200) {
			Set reachable = 1
			Quit
		}
		Hang 1
	}
	If 'reachable Quit $$$ERROR($$$GeneralError, "Issuer did not become reachable: "_..IssuerURL())
	Write "[Demo.Setup] issuer is reachable: ", ..IssuerURL(), !
	Quit $$$OK
}

/// FHIR リポジトリがトークンを確かめるための、クライアント側の設定を作る
ClassMethod ConfigureResourceServer() As %Status
{
	Set sc = $$$OK
	New $Namespace
	Set $Namespace = "%SYS"
	Try {
		Set issuer = ..IssuerURL()
		// 発行元のメタデータ（エンドポイントや公開鍵の場所）を検出して保存する
		If '##class(OAuth2.ServerDefinition).Exists(issuer) {
			$$$ThrowOnError(##class(%SYS.OAuth2.Registration).Discover(issuer, ..#SSLCONFIG, .serverDef))
			$$$ThrowOnError(serverDef.%Save())
		}

		Set rs = ..OpenServerClient(..#RESOURCECLIENT)
		If '$IsObject(rs) $$$ThrowStatus($$$ERROR($$$GeneralError, "Resource client is not registered"))

		Set props("ServerDefinition") = issuer
		Set props("ClientType") = "resource"
		Set props("SSLConfiguration") = ..#SSLCONFIG
		Set props("ClientId") = rs.ClientId
		Set props("ClientSecret") = rs.ClientSecret
		Set props("Enabled") = 1
		If ##class(OAuth2.Client).Exists(..#RESOURCECLIENT) {
			$$$ThrowOnError(##class(OAuth2.Client).Modify(..#RESOURCECLIENT, .props))
		}
		Else {
			$$$ThrowOnError(##class(OAuth2.Client).Create(..#RESOURCECLIENT, .props))
		}

		// FHIR サーバはトークンを確かめるとき、認可サーバのイントロスペクションを呼ぶ。
		// Metadata にクライアントの資格情報がないと "No client authentication included" で失敗する
		Set client = ##class(OAuth2.Client).Open(..#RESOURCECLIENT, .st)
		$$$ThrowOnError(st)
		Set client.Metadata."client_id" = rs.ClientId
		Set client.Metadata."client_secret" = rs.ClientSecret
		Set client.Metadata."token_endpoint_auth_method" = "client_secret_basic"
		$$$ThrowOnError(client.%Save())
		Write "[Demo.Setup] resource server client configured: ", ..#RESOURCECLIENT, !
	}
	Catch ex {
		Set sc = ex.AsStatus()
	}
	Quit sc
}

/// FHIR エンドポイントに OAuth のクライアント設定を紐付ける
ClassMethod AttachOAuthToFHIR() As %Status
{
	Set sc = $$$OK
	New $Namespace
	Try {
		Set $Namespace = ..#NAMESPACE
		// サービスの設定（検索結果の絞り込みなど）は、イメージを作るときに保存したものをそのまま渡す
		Set strategy = ##class(HS.FHIRServer.API.InteractionsStrategy).GetStrategyForEndpoint(..#FHIRAPPKEY)
		Set config = strategy.GetServiceConfigData()
		// UpdateInstance(pAppKey, pServiceConfigData, pEnabled, pServiceConfigName, pOAuthClientName, pDisplayName)
		Do ##class(HS.FHIRServer.Installer).UpdateInstance(..#FHIRAPPKEY, config.AsJSONString(), 1, "", ..#RESOURCECLIENT)
		Write "[Demo.Setup] FHIR endpoint uses OAuth client: ", ..#RESOURCECLIENT, !
	}
	Catch ex {
		Set sc = ex.AsStatus()
	}
	Quit sc
}

/// 確認スクリプトと分析アプリ向けに、発行元やクライアント ID をファイルに書き出す
ClassMethod WriteSharedConfig() As %Status
{
	Set sc = $$$OK
	New $Namespace
	Set $Namespace = "%SYS"
	Try {
		Set app = ..OpenServerClient(..#APPCLIENT)
		If '$IsObject(app) $$$ThrowStatus($$$ERROR($$$GeneralError, "App client is not registered"))
		Set config = {}
		Set config.issuer = ..IssuerURL()
		Set config.fhirBaseUrl = ..BaseURL()_..#FHIRAPPKEY
		Set config.clientId = app.ClientId
		Set config.redirectUri = ..#REDIRECTURI
		Set config.username = ..#DEMOUSER
		Set config.password = ..#DEMOPASSWORD
		Set config.note = "Demo only. Do not reuse these credentials."
		$$$ThrowOnError(..WriteJSONFile(..#SHAREDFILE, config))

		// 分析アプリはブラウザに配信されるので、資格情報を含めない
		Set appConfig = {}
		Set appConfig.fhirBaseUrl = config.fhirBaseUrl
		Set appConfig.clientId = config.clientId
		Set appConfig.redirectUri = config.redirectUri
		$$$ThrowOnError(..WriteJSONFile(..#APPCONFIGFILE, appConfig))
		Write "[Demo.Setup] wrote ", ..#SHAREDFILE, " and ", ..#APPCONFIGFILE, !
	}
	Catch ex {
		Set sc = ex.AsStatus()
	}
	Quit sc
}

ClassMethod WriteJSONFile(pFile As %String, pObject As %DynamicObject) As %Status
{
	Do ##class(%File).Delete(pFile)
	Set file = ##class(%Stream.FileCharacter).%New()
	Set file.TranslateTable = "UTF8"
	Set sc = file.LinkToFile(pFile)
	Quit:$$$ISERR(sc) sc
	Set sc = file.Write(pObject.%ToJSON())
	Quit:$$$ISERR(sc) sc
	Quit file.%Save()
}

/// スコープによる検索結果の絞り込みを切り替える（オフにすると、許可外を含みうる検索が 403 になる）
ClassMethod SetSearchFiltering(pOn As %Boolean = 1) As %Status
{
	Set sc = $$$OK
	New $Namespace
	Try {
		Set $Namespace = ..#NAMESPACE
		Set strategy = ##class(HS.FHIRServer.API.InteractionsStrategy).GetStrategyForEndpoint(..#FHIRAPPKEY)
		Set config = strategy.GetServiceConfigData()
		Set config.SearchFiltering = ''pOn
		Do strategy.SaveServiceConfigData(config)
		Write "[Demo.Setup] SearchFiltering=", config.SearchFiltering, !
	}
	Catch ex {
		Set sc = ex.AsStatus()
	}
	Quit sc
}

/// 登録していないスコープを発行するかを切り替える
ClassMethod SetAllowUnsupportedScope(pAllow As %Boolean = 1) As %Status
{
	Set sc = $$$OK
	New $Namespace
	Set $Namespace = "%SYS"
	Try {
		Set server = ##class(OAuth2.Server.Configuration).Open(.sc)
		$$$ThrowOnError(sc)
		Set server.AllowUnsupportedScope = ''pAllow
		$$$ThrowOnError(server.Save())
		Write "[Demo.Setup] AllowUnsupportedScope=", server.AllowUnsupportedScope, !
	}
	Catch ex {
		Set sc = ex.AsStatus()
	}
	Quit sc
}

/// 認可サーバの主な設定を表示する
ClassMethod ShowOAuthServer(pServer As %RegisteredObject = "")
{
	New $Namespace
	Set $Namespace = "%SYS"
	Try {
		If '$IsObject(pServer) Set pServer = ##class(OAuth2.Server.Configuration).Open()
		Write "[Demo.Setup] OAuth server", !
		Write "  issuer host=", pServer.IssuerEndpoint.Host, " port=", pServer.IssuerEndpoint.Port, " prefix=", pServer.IssuerEndpoint.Prefix, !
		Write "  SupportedGrantTypes=", pServer.SupportedGrantTypes, " AllowUnsupportedScope=", pServer.AllowUnsupportedScope, " ForcePKCEForPublicClients=", pServer.ForcePKCEForPublicClients, " DefaultScope=", pServer.DefaultScope, !
		Write "  AuthenticateClass=", pServer.AuthenticateClass, " ValidateUserClass=", pServer.ValidateUserClass, " GenerateTokenClass=", pServer.GenerateTokenClass, !
		Write "  CustomizationNamespace=", pServer.CustomizationNamespace, " CustomizationRoles=", pServer.CustomizationRoles, " SSLConfiguration=", pServer.SSLConfiguration, !
		Write "  SigningAlgorithm=", pServer.SigningAlgorithm, " AudRequired=", pServer.AudRequired, " AccessTokenInterval=", pServer.AccessTokenInterval, !
	}
	Catch ex {
		Write "  (could not show all properties: ", ex.DisplayString(), ")", !
	}
}

/// 名前から、認可サーバ側のクライアント登録を開く（なければ空文字を返す）
ClassMethod OpenServerClient(pName As %String) As %RegisteredObject
{
	New $Namespace
	Set $Namespace = "%SYS"
	Set id = ""
	&sql(SELECT ID INTO :id FROM OAuth2_Server.Client WHERE Name = :pName)
	If SQLCODE '= 0 Quit ""
	Quit ##class(OAuth2.Server.Client).%OpenId(id)
}

}
