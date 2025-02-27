require('app/styles/modal/subscribe-modal.sass')
api = require 'core/api'
ModalView = require 'views/core/ModalView'
template = require 'app/templates/core/subscribe-modal'
stripeHandler = require 'core/services/stripe'
utils = require 'core/utils'
CreateAccountModal = require 'views/core/CreateAccountModal'
Products = require 'collections/Products'
payPal = require('core/services/paypal')
paymentUtils = require '../../lib/paymentUtils'

module.exports = class SubscribeModal extends ModalView
  id: 'subscribe-modal'
  template: template
  plain: true
  closesOnClickOutside: false
  planID: 'basic'
  i18nData: utils.premiumContent

  events:
    'click #close-modal': 'hide'
    'click .purchase-button': 'onClickPurchaseButton'
    'click .stripe-lifetime-button': 'onClickStripeLifetimeButton'
    'click .stripe-annual-button': 'onClickAnnualPurchaseButton'
    'click .back-to-products': 'onClickBackToProducts'

  constructor: (options={}) ->
    #if document.location.host is 'br.codecombat.com'
    #  document.location.href = 'http://codecombat.net.br/'

    super(options)
    # Path check due to modal refresh when user isn't signed in.
    @hideMonthlySub = options?.hideMonthlySub or window.location.pathname.startsWith('/parents') or me.get('country') is 'japan' or null
    @state = 'standby'
    @couponID = utils.getQueryVariable('coupon')
    @subModalContinue = options.subModalContinue
    if options.products
      # this is just to get the test demo to work
      @products = options.products
      @onLoaded()
    else
      @products = new Products()
      data = {}

      # Attempt to get the coupon associated with the user's country.
      # If coupon doesn't exist nothing is returned.
      @couponID ?= me?.get('country')
      if @couponID is 'brazil'
        # Edge case due to misconfigured brazil coupon in stripe that is immutable
        @couponID = 'brazil-annual'

      if @couponID
        data.coupon = @couponID
      @supermodel.trackRequest @products.fetch {data}
    @trackTimeVisible({ trackViewLifecycle: true })
    payPal.loadPayPal().then => @render()

  onLoaded: ->
    @basicProduct = @products.getBasicSubscriptionForUser(me)
    @basicProductAnnual = @products.getBasicAnnualSubscriptionForUser()
    # Process basic product coupons unless custom region pricing
    if @couponID and @basicProduct?.get('coupons')? and @basicProduct?.get('name') is 'basic_subscription'
      @basicCoupon = _.find(@basicProduct.get('coupons'), {code: @couponID})
    if @couponID and @basicProductAnnual?.get('coupons')? and @basicProductAnnual?.get('name') is 'basic_subscription_annual'
      @basicCouponAnnual = _.find(@basicProductAnnual.get('coupons'), {code: @couponID})
    @lifetimeProduct = @products.getLifetimeSubscriptionForUser(me)
    @paymentProcessor = 'stripe' # Always use Stripe
    super()
    @render()

  render: ->
    return if @state is 'purchasing'
    super(arguments...)
    # NOTE: The PayPal button MUST NOT be removed from the page between clicking it and completing the payment, or the payment is cancelled.
    @renderPayPalButton()
    null

  renderPayPalButton: ->
    if @$('#paypal-button-container').length and not @$('#paypal-button-container').children().length
      descriptionTranslationKey = 'subscribe.lifetime'
      discount = @basicProduct.get('amount') * 12 - @lifetimeProduct.get('amount')
      discountString = (discount/100).toFixed(2)
      description = $.i18n.t(descriptionTranslationKey).replace('{{discount}}', discountString)
      payPal?.makeButton({
        buttonContainerID: '#paypal-button-container'
        product: @lifetimeProduct
        onPaymentStarted: @onPayPalPaymentStarted
        onPaymentComplete: @onPayPalPaymentComplete
        description
      })

  afterRender: ->
    super()
    # TODO: does this work?
    @playSound 'game-menu-open'
    if @basicProduct and @subModalContinue
      if @subModalContinue is 'monthly'
        @subModalContinue = null
        @onClickPurchaseButton()
      else if @subModalContinue is 'lifetime'
        @subModalContinue = null
        # Only automatically open lifetime payment dialog for Stripe, not PayPal
        unless @basicProduct.isRegionalSubscription()
          @onClickStripeLifetimeButton()

  stripeOptions: (options) ->
    return _.assign({
      alipay: if me.get('country') is 'china' or (me.get('preferredLanguage') or 'en-US')[...2] is 'zh' then true else 'auto'
      alipayReusable: true
    }, options)

  onClickPurchaseButton: (e) ->
    return unless @basicProduct
    @playSound 'menu-button-click'
    if me.get('anonymous')
      service = if @basicProduct.isRegionalSubscription() then 'paypal' else 'stripe'
      application.tracker?.trackEvent 'Started Signup from buy monthly', {service}
      return @openModalView new CreateAccountModal({startOnPath: 'individual', subModalContinue: 'monthly'})
    # if @basicProduct.isRegionalSubscription()
    #   @startPayPalSubscribe()
    # else
    #   @startStripeSubscribe()
    @startStripeSubscribe() # Always use Stripe

  onClickAnnualPurchaseButton: (e) ->
    return unless @basicProductAnnual
    @playSound 'menu-button-click'
    if me.get('anonymous')
      application.tracker?.trackEvent 'Started Signup from buy yearly', {service: 'stripe'}
      return @openModalView new CreateAccountModal({startOnPath: 'individual', subModalContinue: 'yearly'})

    @startYearlyStripeSubscription()

  startPayPalSubscribe: ->
    application.tracker?.trackEvent 'Started subscription purchase', { service: 'paypal' }
    $('.purchase-button').addClass("disabled")
    $('.purchase-button').html($.i18n.t('common.processing'))
    api.users.createBillingAgreement({userID: me.id, productID: @basicProduct.id})
    .then (billingAgreement) =>
      for link in billingAgreement.links
        if link.rel is 'approval_url'
          application.tracker?.trackEvent 'Continue subscription purchase', { service: 'paypal', redirectUrl: link.href }
          window.location = link.href
          return
      throw new Error("PayPal billing agreement has no redirect link #{JSON.stringify(billingAgreement)}")
    .catch (jqxhr) =>
      $('.purchase-button').removeClass("disabled")
      $('.purchase-button').html($.i18n.t('premium_features.subscribe_now'))
      @onSubscriptionError(jqxhr)

  startStripeSubscribe: ->
    @startStripeSubscription(@basicProduct)

  startYearlyStripeSubscription: ->
    @startStripeSubscription(@basicProductAnnual)

  ###
    Starts a stripe subscription based on the product passed in.
  ###
  startStripeSubscription: (product) ->
    paymentUtils.handleHomeSubscription(product, @couponID)
      .catch (err) =>
        console.error 'homeSubscription handle failed by new stripe', err
        @handleStripeSubscriptionByOldFormat(product)

  handleStripeSubscriptionByOldFormat: (product) ->
    application.tracker?.trackEvent 'Started subscription purchase', { service: 'stripe' }
    options = @stripeOptions {
      description: if product.get('name') is 'basic_subscription_annual' then $.i18n.t('subscribe.stripe_yearly_description') else $.i18n.t('subscribe.stripe_description')
      amount: product.adjustedPrice()
    }

    @purchasedAmount = options.amount
    stripeHandler.makeNewInstance().openAsync(options)
    .then ({token}) =>
      @state = 'purchasing'
      @render()
      jqxhr = if product.get('name') is 'basic_subscription_annual'
        me.subscribe(token, { planID: product.get('planID'), couponID: @basicCouponAnnual?.code })
      else if @basicCoupon?.code
        me.subscribe(token, {couponID: @basicCoupon.code})
      else
        me.subscribe(token)
      return Promise.resolve(jqxhr)
    .then =>
      application.tracker?.trackEvent 'Finished subscription purchase', { value: @purchasedAmount, service: 'stripe' }
      @onSubscriptionSuccess()
    .catch (jqxhr) =>
      return unless jqxhr # in case of cancellations
      stripe = me.get('stripe') ? {}
      delete stripe.token
      delete stripe.planID
      @onSubscriptionError(jqxhr, 'Failed to finish subscription purchase')

  makePurchaseOps: ->
    out = {data: {}}
    out.data.coupon = @couponID if @couponID
    out

  # For lifetime subs
  onPayPalPaymentStarted: =>
    @playSound 'menu-button-click'
    if me.get('anonymous')
      application.tracker?.trackEvent 'Started Signup from buy lifetime', {service: 'paypal'}
      return @openModalView new CreateAccountModal({startOnPath: 'individual', subModalContinue: 'lifetime'})
    startEvent = 'Start Lifetime Purchase'
    application.tracker?.trackEvent startEvent, { service: 'paypal' }
    @state = 'purchasing'
    @render() # TODO: Make sure this doesn't break paypal from button regenerating

  # For lifetime subs
  onPayPalPaymentComplete: (payment) =>
    # NOTE: payment is a PayPal payment object, not a CoCo Payment model
    # TODO: Send payment info to server, confirm it
    finishEvent = 'Finish Lifetime Purchase'
    failureMessage = 'Fail Lifetime Purchase'
    @purchasedAmount = Number(payment.transactions[0].amount.total) * 100
    return Promise.resolve(@lifetimeProduct.purchaseWithPayPal(payment, @makePurchaseOps()))
    .then (response) =>
      application.tracker?.trackEvent finishEvent, { value: @purchasedAmount, service: 'paypal' }
      me.set 'payPal', response?.payPal if response?.payPal?
      @onSubscriptionSuccess()
    .catch (jqxhr) =>
      return unless jqxhr # in case of cancellations
      @onSubscriptionError(jqxhr, failureMessage)

  onClickStripeLifetimeButton: ->
    @playSound 'menu-button-click'
    if me.get('anonymous')
      application.tracker?.trackEvent 'Started Signup from buy lifetime', {service: 'stripe'}
      return @openModalView new CreateAccountModal({startOnPath: 'individual', subModalContinue: 'lifetime'})
    @startStripeSubscription(@lifetimeProduct)
      .catch (err) =>
        console.error 'stripe lifetime handle failed', err
        @oldStripeLifetimeHandle()

  oldStripeLifetimeHandle: ->
    startEvent = 'Start Lifetime Purchase'
    finishEvent = 'Finish Lifetime Purchase'
    descriptionTranslationKey = 'subscribe.lifetime'
    failureMessage = 'Fail Lifetime Purchase'
    application.tracker?.trackEvent startEvent, { service: 'stripe' }
    discount = @basicProduct.get('amount') * 12 - @lifetimeProduct.get('amount')
    discountString = (discount/100).toFixed(2)
    options = @stripeOptions {
      description: $.i18n.t(descriptionTranslationKey).replace('{{discount}}', discountString)
      amount: @lifetimeProduct.adjustedPrice()
    }
    @purchasedAmount = options.amount
    stripeHandler.makeNewInstance().openAsync(options)
    .then ({token}) =>
      @state = 'purchasing'
      @render()
      # Purchasing a lifetime sub
      return Promise.resolve(@lifetimeProduct.purchase(token, @makePurchaseOps()))
    .then (response) =>
      application.tracker?.trackEvent finishEvent, { value: @purchasedAmount, service: 'stripe' }
      me.set 'stripe', response?.stripe if response?.stripe?
      @onSubscriptionSuccess()
    .catch (jqxhr) =>
      return unless jqxhr # in case of cancellations
      @onSubscriptionError(jqxhr, failureMessage)

  onSubscriptionSuccess: ->
    @playSound 'victory'
    me.fetch().then =>
      Backbone.Mediator.publish 'subscribe-modal:subscribed', {}
      @hide()

  onSubscriptionError: (jqxhrOrError, errorEventName) ->
    jqxhr = null
    error = null
    message = ''
    if jqxhrOrError instanceof Error
      error = jqxhrOrError
      console.error error.stack
      message = error.message
    else
      # jqxhr
      jqxhr = jqxhrOrError
      message = "#{jqxhr.status}: #{jqxhr.responseJSON?.message or jqxhr.responseText}"
    application.tracker?.trackEvent(errorEventName, {status: message, value: @purchasedAmount})
    if jqxhr?.status is 402
      @state = 'declined'
    else if jqxhr?.responseJSON?.i18n
      @state = 'error'
      @stateMessage = $.i18n.t(jqxhr.responseJSON.i18n)
    else
      @state = 'unknown_error'
      @stateMessage = $.i18n.t('loading_error.unknown')
    @render()

  onHidden: ->
    super()
    @playSound 'game-menu-close'
