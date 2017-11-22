---
layout: post
title: "Playframework Silhouette 用户框架之基本配置和 Json Web Token 生成篇"
date: 2017-11-21 03:36:53 +0800
comments: true
categories: scala framework silhouette
---

* 添加依赖
{% codeblock build.sbt lang:scala %}
  libraryDependencies ++= Seq("com.mohiva" %% "play-silhouette" % "4.0.0",
  "com.mohiva" %% "play-silhouette-password-bcrypt" % "4.0.0",
  "com.mohiva" %% "play-silhouette-persistence" % "4.0.0" // 如果想让 token stateful 就需引入
  )
{% endcodeblock %}
<!-- more -->
* 创建配置文件
{% codeblock silhouette.conf lang:scala %}
silhouette {
  // 定义 JWT 的 header 属性
  authenticator.headerName = "X-Auth-Token" // 在 http 头中的字段名
  authenticator.issuerClaim = "waylens"
  authenticator.encryptSubject = false
  authenticator.authenticatorExpiry = "365d"
  authenticator.sharedSecret= "changeme"

  # Google provider
  google.authorizationURL=
  google.accessTokenURL=
  google.redirectURL=
  google.clientID=
  google.clientSecret=
  google.scope=
}
{% endcodeblock %}
* 创建依赖配置类 SilhouetteModule
{% codeblock SilhouetteModule.scala lang:scala %}
class EmptyIDGenerator extends IDGenerator {
  def generate: Future[String] = Future.successful("")
}

/**
 * 用 Guice 的 AbstractModule 把 Silhouette 的所有依赖装配起来
 * 注意后面的组件装配会依赖到前面的装配
 */

class SilhouetteModule extends AbstractModule with ScalaModule {

  /**
   * Configures the module.
   */
  def configure() {
    bind[UserDAO].to[UserDAOPsqlImpl]
    bind[CacheLayer].to[PlayCacheLayer]
    bind[OAuth2StateProvider].to[DummyStateProvider]
    bind[IDGenerator].to[EmptyIDGenerator]
    bind[PasswordHasher].toInstance(new BCryptPasswordHasher)
    bind[EventBus].toInstance(EventBus())
    bind[Clock].toInstance(Clock())
    bind[Silhouette[JWTEnv]].to[SilhouetteProvider[JWTEnv]]
    bind[SecuredErrorHandler].to[JsonResponseErrorHandler]
    bind[AuthenticatorEncoder].to[Base64AuthenticatorEncoder]
  }

  @Provides
  def provideHTTPLayer(client: WSClient): HTTPLayer = new PlayHTTPLayer(client)

  @Provides
  def provideAuthenticatorService(
    cacheLayer: CacheLayer,
    authenticatorEncoder: AuthenticatorEncoder,
    idGenerator: IDGenerator,
    configuration: Configuration,
    clock: Clock): AuthenticatorService[JWTAuthenticator] = {

    val config = JWTAuthenticatorSettings(
      fieldName = configuration.underlying.as[String]("silhouette.authenticator.headerName"),
      issuerClaim = configuration.underlying.as[String]("silhouette.authenticator.issuerClaim"),
      authenticatorExpiry = configuration.underlying.as[FiniteDuration]("silhouette.authenticator.authenticatorExpiry"),
      sharedSecret = configuration.underlying.as[String]("silhouette.authenticator.sharedSecret"))
    new JWTAuthenticatorService(config, None, authenticatorEncoder, idGenerator, clock)
  }

  @Provides
  def provideEnvironment(
    userService: UserService,
    authenticatorService: AuthenticatorService[JWTAuthenticator],
    eventBus: EventBus): Environment[JWTEnv] = {

    Environment[JWTEnv](
      userService,
      authenticatorService,
      Seq.empty,
      eventBus
    )
  }

  @Provides
  def provideAvatarService(httpLayer: HTTPLayer): AvatarService = new GravatarService(httpLayer)

  @Provides
  def provideGoogleProvider(
    httpLayer: HTTPLayer,
    stateProvider: OAuth2StateProvider,
    configuration: Configuration): GoogleProvider = {

    new GoogleProvider(httpLayer, stateProvider, configuration.underlying.as[OAuth2Settings]("silhouette.google"))
  }
}
{% endcodeblock %}
  核心：bind[_Silhouette_[JWTEnv]].to[_SilhouetteProvider_[JWTEnv]]
{% codeblock SilhouetteProvider 在库中定义 lang:scala %}
class SilhouetteProvider[E <: Env] @Inject() (
  val env: Environment[E],
  val securedAction: SecuredAction,
  val unsecuredAction: UnsecuredAction,
  val userAwareAction: UserAwareAction)
  extends Silhouette[E]

// 配置类提供了其所需要的 Environment
@Provides
def provideEnvironment(
  userService: UserService,
  authenticatorService: AuthenticatorService[JWTAuthenticator],
  eventBus: EventBus): Environment[JWTEnv] = {

  Environment[JWTEnv](
    userService,
    authenticatorService,
    Seq.empty,
    eventBus
  )
}
{% endcodeblock %}
  
* 在 play 配置文件中启用 SilhouetteModule 模块
{% codeblock application.conf lang:scala %}
play.modules {
  enabled += "modules.SilhouetteModule"
  ...
}
{% endcodeblock %}
* 注册、登录时生成 (新)token
{% codeblock 依赖的库源码 lang:scala %}
case class HornIdentity(
    userID: String,
    email: Option[String],
    userName: String,
    displayName: String,
    avatarUrl: String,
    isVerified: Boolean,
    jwtVersion: String)

trait JWTEnv extends Env {
  type I = HornIdentity
  type A = JWTAuthenticator
}

trait ExpirableAuthenticator extends Authenticator {
  
  val lastUsedDateTime: DateTime

  val expirationDateTime: DateTime

  val idleTimeout: Option[FiniteDuration]

  override def isValid = !isExpired && !isTimedOut

  def isExpired = expirationDateTime.isBeforeNow

  def isTimedOut = idleTimeout.isDefined && (lastUsedDateTime + idleTimeout.get).isBeforeNow
}

case class LoginInfo(providerID: String, providerKey: String)

case class JWTAuthenticator(
  id: String,
  loginInfo: LoginInfo,
  lastUsedDateTime: DateTime,
  expirationDateTime: DateTime,
  idleTimeout: Option[FiniteDuration],
  customClaims: Option[JsObject] = None)
  extends StorableAuthenticator with ExpirableAuthenticator {

  /**
   * The Type of the generated value an authenticator will be serialized to.
   */
  override type Value = String
}

trait AuthenticatorService[T <: Authenticator] extends ExecutionContextProvider {
  /**
   * Creates a new authenticator for the specified login info.
   */
  def create(loginInfo: LoginInfo)(implicit request: RequestHeader): Future[T]

  /**
   * Retrieves the authenticator from request.
   */
  def retrieve[B](implicit request: ExtractableRequest[B]): Future[Option[T]]

  /**
   * Initializes an authenticator and instead of embedding into the the request or result, it returns
   * the serialized value.
   */
  def init(authenticator: T)(implicit request: RequestHeader): Future[T#Value]
  ...
}
{% endcodeblock %}

{% codeblock 主代码 lang:scala %}
class UserController @Inject()(userService: UserService, silhouette: Silhouette[JWTEnv]) extends Controller {
  def signin = Action.async(parse.json) { implicit request =>
    ...
    // 按某种加密算法校验邮箱密码是否正确，是的话返回用户信息
    userService.authenticate(email, password).map { 
      case Some(user) =>
        (for {
          loginID <- userService.login(user, deviceType, deviceID)
          /**
          * create 的函数定义为： 
          * def create(loginInfo: LoginInfo)(implicit request: RequestHeader): Future[T]
          * T 会被解析为 JWTEnv#A，且 type A = JWTAuthenticator，
          * 因此 authenticator 的类型为 JWTAuthenticator，
          * 同时给 authenticator 传入了自定义的 token 版本号
          *
          * init 的函数定义为：
          * def init(authenticator: T)(implicit request: RequestHeader): Future[T#Value]
          * 因此 token 类型为 JWTEnv#A#Value = JWTAuthenticator#Value = String，
          * 即是 JWTAuthenticator 为该 LoginInfo(providerID: String, providerKey: String) + jwtVersion 生成的一个令牌，
          * 其中只要有一项未通过服务器校验，token 即非法
          **/
          authenticator <- 
            silhouette.env.authenticatorService
              .create(LoginInfo(ProviderKey.waylens.id.toString, user.userID))
              .map(_.copy(id = loginID.toString, customClaims = Some(JsObject(Map("version"-> JsString(user.jwtVersion))))))
          token <- silhouette.env.authenticatorService.init(authenticator)
        } yield (token, authenticator)).map {
          case (token, authenticator) =>
            val res = SigninResponse(
              user.identity.waylensUser,
              token,
              // 同时返回 token 有效时长
              authenticator.expirationDateTime.getMillis / 1000 * 1000)
            ok(res)
        }
      case None => ...
    }
  }
}
{% endcodeblock %}

* 核心小结

  1. 后台随机生成 userID ，组装成 **LoginInfo**

  * **AuthenticatorService.create**(loginInfo) 得到 **JWTAuthenticator**， 接着可以向它塞进 _JWTVersion_ 等客制化校验信息

  * **AuthenticatorService.init**(jwtAuthenticator) 得到 token，这里会按 JWTAuthenticator 的类型对 jwtAuthenticator 所携带信息（LoginInfo, JWTVersion 等）进行加密得到一个 JWT（**header.payload.secret**）

  * userID -> LoginInfo -> JWTAuthenticator -> token

{% codeblock 让我再看你一遍 JWTAuthenticator lang:scala %}
JWTAuthenticator(
  id: String,
  loginInfo: LoginInfo,
  lastUsedDateTime: DateTime,
  expirationDateTime: DateTime,
  idleTimeout: Option[FiniteDuration],
  customClaims: Option[JsObject] = None)
{% endcodeblock %}