Include %occStatus

/// 内蔵の認可サーバが使う検証クラス。
/// IRIS for Health の SMART on FHIR 用クラス（HS.HC.OAuth2.Server.Validate）を拡張し、
/// アプリが fhirUser スコープを要求したとき、ログインした利用者に対応する FHIR リソース
/// （例: Practitioner/pr-001）を fhirUser クレームとしてトークンに入れる。
/// 認可サーバのカスタマイズ用ネームスペース（HSSYS）に読み込む。
Class Demo.OAuth2.Validate Extends HS.HC.OAuth2.Server.Validate
{

/// トークンに入れてよいクレームに fhirUser を加える。
/// 親クラスが既定で受け付けるのは、名前やメールアドレスなどと、SMART のコンテキスト（patient、encounter）だけ
Parameter AdditionalSupportedClaims = {$ListBuild("fhirUser")};

/// 親クラスの処理（利用者の確認と、認可リクエストの claims パラメータの反映）のあとに、fhirUser を加える。
/// fhirUser の値はアプリではなく認可サーバが決める。デモでは ^Demo.FHIRUser(利用者名) に対応を持つ
ClassMethod ValidateUserLocal(pUsername As %String, pPassword As %String, pScope As %ArrayOfDataTypes, pProperties As %OAuth2.Server.Properties, Output pStatus As %Status, Output pUse2fa As %Boolean = 0) As %Boolean
{
	Set ok = ##super(pUsername, pPassword, pScope, pProperties, .pStatus, .pUse2fa)
	If ('ok) || $$$ISERR(pStatus) Quit ok

	// 親クラスは、認可リクエストの claims パラメータで渡された値も、受け付けるクレームならトークンに入れる。
	// fhirUser を受け付けるクレームに加えたので、そのままだとアプリが別人の fhirUser を入れられてしまう。
	// いったん消してから、認可サーバの対応表の値だけを入れ直す
	Do pProperties.RemoveClaimValue("fhirUser")
	If $IsObject(pScope) && pScope.IsDefined("fhirUser") {
		Set fhirUser = $Get(^Demo.FHIRUser(pUsername))
		If fhirUser '= "" {
			Do pProperties.SetClaimValue("fhirUser", fhirUser)
		}
	}
	Quit 1
}

}
