---
layout: post
title: "Playframework Silhouette 用户框架之权限校验篇"
date: 2017-11-21 17:31:00 +0800
comments: true
categories: scala framework silhouette
---

[上篇](http://kdleong.com/blog/2017/11/21/silhouette1/) 说到了客户发送 `用户名+密码` 请求 `注册/登录` 后，后台先通过密码校验，再通过 AuthenticatorService 来创建 Authenticator 进而生成 `token`，本篇就来说说客户拿到该 `token` 后如何敲进后台的大门。
<!-- more -->
* 探秘 SecuredAction
{% codeblock SecuredAction 做了啥 lang:scala %}

// 你没看错，在 controller 中校验就是这么简洁
class Application(silhouette: Silhouette[DefaultEnv]) extends Controller {

  def myAction = silhouette.SecuredAction() { implicit request =>
    // do something here
  }
}

// 回顾一下 Environment 用了我写的 UserService 进行装配
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

// UserService 继承 IdentityService 并实现了 retrieve
class UserService @Inject()(userDAO: UserDAO) extends
  IdentityService[MyIdentity] with Logger {

  /**
    * Retrieves a user that matches the specified login info.
    */
  def retrieve(loginInfo: LoginInfo): Future[Option[MyIdentity]] = {
    val userID = loginInfo.providerKey
    userDAO.getUserInfo(userID)
  }
}
{% endcodeblock %}
  这样 SecuredAction 在背后做的事情就是：
> 1. 解析 request header ，按预先 JWT 协议读取 token 并解析出 LoginInfo
> 2. 调用 UserService.retrieve 去获取用户信息(identity)
> 3. 如果拿到有效信息，将用户信息塞进 request.identity 中传给后面的代码，否则跳过后面代码（至于到哪去，下篇详解）

* 通过自定义 `授权校验类` 进行 `客制化校验`
{% codeblock SecuredAction 做了啥 lang:scala %}
trait Authorization[I <: Identity, A <: Authenticator] {

  /**
   * Checks whether the user is authorized to execute an endpoint or not.
   *
   * @param identity The current identity instance.
   * @param authenticator The current authenticator instance.
   * @param request The current request.
   * @tparam B The type of the request body.
   * @return True if the user is authorized, false otherwise.
   */
  def isAuthorized[B](identity: I, authenticator: A)(
    implicit request: Request[B]): Future[Boolean]
}

case class WithProvider(provider: String) extends Authorization[User, CookieAuthenticator] {
  
  def isAuthorized[B](user: User, authenticator: CookieAuthenticator)(
    implicit request: Request[B]) = {
    
    Future.successful(user.loginInfo.providerID == provider)
  }
}
{% endcodeblock %}

* 核心小结
  1. UserService _-Environment[JWTEnv]->_ Silhouette
  2. request header _-Silhouette.SecuredAction->_ JWT -> LoginInfo
  3. LoginInfo _-UserService.retrieve->_ Option[Identity] _-Silhouette.SecuredAction->_ request -> do something