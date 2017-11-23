---
layout: post
title: "Playframework Silhouette 用户框架官方文档整理"
date: 2017-11-23 18:11:01 +0800
comments: true
categories: scala framework silhouette
---

本文整合下 [Silhouette 官方文档](https://www.silhouette.rocks/docs) 要点，纯粹摘录以备忘，完整请参考原链。
<!-- more -->
## Environment

> An application can provide different environments for different environment types. With this it's possible to create endpoints that can handle different identitity -> authenticator combinations.

## RequestHandler

> In Silhouette, request handlers are the foundation to handle secured endpoints and the building blocks for the more specific action types. A request handler can execute an arbitrary block of code and must return a HandlerResult.
>
> There exists a SecuredRequestHandler which intercepts requests and checks if there is an authenticated user. If there is one, the execution continues and the enclosed code is invoked.
{% codeblock SecuredRequestHandler lang:scala %}
def securedRequestHandler = Action.async { implicit request =>
  silhouette.SecuredRequestHandler { securedRequest =>
    Future.successful(HandlerResult(Ok, Some(securedRequest.identity)))
  }.map {
    case HandlerResult(r, Some(user)) => Ok(Json.toJson(user.loginInfo))
    case HandlerResult(r, None) => Unauthorized
  }
}
{% endcodeblock %}
Silhouette provides a replacement for Play’s built in Action class named **SecuredAction** which is based on the SecuredRequestHandler
{% codeblock SecuredAction lang:scala %}
def index = silhouette.SecuredAction { implicit request =>
  Ok(views.html.index(request.identity))
}
{% endcodeblock %}

## Error handlers
> If the access to an endpoint will be denied then it's possible to provide an error handler to handle the incoming request and return an appropriate result.
>
> Every request handler may provide it's own error handler implementation. 

All different types of error handlers:
> Local error handlers
>
> Exception handler
>
> UnsecuredErrorHandler
>
> SecuredErrorHandler

{% codeblock SecuredErrorHandler lang:scala %}
class CustomSecuredErrorHandler extends SecuredErrorHandler {

  /**
    * Called when a user is not authenticated.
    */
  override def onNotAuthenticated(implicit request: RequestHeader) = {
    Future.successful(Unauthorized)
  }
  
  /**
    * Called when a user is authenticated but not authorized.
    */
  override def onNotAuthorized(implicit request: RequestHeader) = {
    Future.successful(Forbidden)
  }
}

// bind it in SilhouetteModule.scala
..
bind[SecuredErrorHandler].to[CustomSecuredErrorHandler]
..
{% endcodeblock %}

## Filters
> Play provides a simple filter API for applying global filters to each request. Such a filter is basically the same as an action. It produces a request and returns a result. 
>
> So it's possible to use the actions provided by Silhouette inside a filter to create a global authentication mechanism.
{% codeblock Filter lang:scala %}
class SecuredFilter @Inject() (silhouette: Silhouette[DefaultEnv], bodyParsers: PlayBodyParsers) extends Filter {

  override def apply(next: RequestHeader => Future[Result])(
    request: RequestHeader): Future[Result] = {
    
    // As the body of request can't be parsed twice in Play we should force 
    // to parse empty body for UserAwareAction
    val action = silhouette.UserAwareAction.async(bodyParsers.empty) { r =>
      request.path match {
        case "/admin" if r.identity.isEmpty => Future.successful(Unauthorized)
        case _ => next(request)
      }
    }
    
    action(request).run
  }
}
{% endcodeblock %}

## Authorization
> Silhouette provides a way to add authorization logic to your secured endpoints. This is done by implementing an Authorization object that is passed to all SecuredRequestHandler and SecuredAction as a parameter.
{% codeblock Filter lang:scala %}
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

class Application(silhouette: Silhouette[DefaultEnv]) extends Controller {

  def myAction = silhouette.SecuredAction(WithProvider("twitter")) { implicit request =>
    // do something here
  }
}
{% endcodeblock %}
You can use the logical `!`, `&&` and `||` operators to create logical expressions with your Authorization instances. You also need to have an implicit ExecutionContext in scope.

## Iddentity
> Silhouette defines a user through its Identity trait. This trait doesn't define any defaults. Thus, you are free to design your user according to your needs.
>
> The LoginInfo case class acts as Silhouette’s identity ID, and it helps identify users in the Silhouette workflow.

{% codeblock IdentityService lang:scala %}
class UserService(userDAO: UserDAO) extends IdentityService[User] {

  /**
   * Retrieves a user that matches the specified login info.
   */
  def retrieve(loginInfo: LoginInfo): Future[Option[User]] = userDAO.findByLoginInfo(loginInfo)
}
{% endcodeblock %}

## Authenticator & Authenticator Service
> Authenticator recognizes a user on every request after a successful authentication.
>
> It's a small class which stores only some data like its validity and the linked login information for an identity

* Every Authenticator has an associated **Authenticator Service** which implements the Authenticator's functionality. This service is responsible for the following actions:

  1. _Create_ an Authenticator
    > Creates a new Authenticator from the an identity's login information. This action should be executed after a successful authentication. 
    >
    > The created Authenticator can then be used to recognize the user on every subsequent request.

  2. _Initialize_ an Authenticator

  3. _Embed_ an Authenticator
    > After initialization, an Authenticator must be embedded into a Play framework request or result. Embedding the Authenticator-related data into the result means that the data will be sent to the client. 
    >
    > It may also be useful to embed the Authenticator-related data into an incoming request to lead a Silhouette endpoint to believe that the request is a new request which contains a valid Authenticator. This is typically done in tests or Play filters.

  4. _Touch_ an Authenticator

  5. _Update_ an Authenticator
    > Automatically updates the state of an Authenticator on every request to a Silhouette endpoint. Updated Authenticators will be embedded into the Play framework result before sending it to the client. 
    >
    > If the service uses a backing store, then the Authenticator instance will be updated in the store, too.

  6. _Renew_ an Authenticator
    > Authenticators have a fixed expiration date. With this method it is possible to renew the expiration of an Authenticator by discarding the old one and creating a new one.

  7. _Discard_ an Authenticator


* Different types of Authenticator:

  1. CookieAuthenticator
  > It works either by storing an ID in a cookie to track the authenticated user and a server-side backing store that maps the ID to an Authenticator instance or by a stateless approach that stores the Authenticator in a serialized form directly into the cookie.
  2. SessionAuthenticator
  > It works by storing a serialized authenticator instance in the Play Framework session cookie.
  3. BearerTokenAuthenticator
  > It works by transporting a token in a user-defined header to track the authenticated user and a server-side backing store that maps the token to an Authenticator instance.
  4. JWTAuthenticator
  > The JWTAuthenticator uses a header-based approach with the help of a [JWT] (JSON Web Token). It works by using a JWT to transport the Authenticator data inside a user-defined header. It can be stateless with the disadvantages that the JWT can’t be invalidated.
  >
  > The stateful or stateless approach is selected depending on whether a AuthenticatorRepository was supplied to the authenticator service.
  5. DummyAuthenticator

## Provider
> In Silhouette a provider is a service that handles the authentication of an identity. It typically reads authorization information and returns information about an identity.

## Persistence
Silhouette has only two points where it needs to read or write data from an underlying persistence layer:

* Authenticators
> Some authenticators have the need to persistent either the complete authenticator or parts of the authenticator in a backing store. These kind of authenticators have a dependency to the AuthenticatorRepository which provides a well defined interface

* Providers
> Currently the password based providers like the BasicAuthProvider or the CredentialsProvider needs the ability to read the PasswordInfo from a persistence layer during authentication.
> 
>These kind of providers have a dependency to the AuthInfoRepository, which provides a well defined interface, that can be implemented to persistent the AuthInfo into any kind of data storage.
{% codeblock Persistence lang:scala%}
  libraryDependencies ++= Seq(
  "com.mohiva" %% "play-silhouette-persistence" % "4.0.0"
  )

  In the package, there are:
  CacheAuthenticatorRepository
    An implementation of the AuthenticatorRepository which uses a cache to store the authenticator artifacts.
    
  DelegableAuthInfoRepository
    An implementation of the AuthInfoRepository which delegates the storage of an AuthInfo instance to its appropriate DAO
{% endcodeblock %}

## Rate limiting
> You can do this with [play-guard](https://github.com/sief/play-guard).

{% codeblock Rate limiting lang:scala %}
  object UserLimiter {...}

  class MyController @Inject()(silhouette: Silhouette[MyEnv])(implicit ac: ActorSystem) extends Controller {

  private val defaultUserFilter = UserLimiter.defaultUserFilter
  
  def myAction: Action[AnyContent] = (silhouette.SecuredAction andThen defaultUserFilter).async {
    implicit request =>
      
    //..Your custom logic here
  }
}
{% endcodeblock %}

## Events
> Silhouette provides event handling based on Akka’s Event Bus.

## Logging
{% codeblock log setting lang:scala %}
  <configuration debug="false">
    ...
    <logger name="com.mohiva" level="ERROR" />
    <logger name="com.mohiva.play.silhouette.api.Silhouette" level="INFO" />
    ...
  </configuration>
{% endcodeblock %}
To use the named logger you only need to mix the Logger trait into your class or trait.