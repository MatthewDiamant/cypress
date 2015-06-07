root         = '../../../'
sinon        = require "sinon"
chokidar     = require "chokidar"
expect       = require('chai').expect
fs           = require "fs-extra"
touch        = require "touch"
Socket       = require "#{root}lib/socket"
Server       = require "#{root}lib/server"
Settings     = require "#{root}lib/util/settings"
Fixtures     = require "#{root}/spec/server/helpers/fixtures"

describe "Socket", ->
  beforeEach ->
    @sandbox = sinon.sandbox.create()

    @ioSocket =
      on: @sandbox.stub()
      emit: @sandbox.stub()

    @io =
      of: @sandbox.stub().returns({on: ->})
      on: @sandbox.stub().callsArgWith(1, @ioSocket)
      emit: @sandbox.stub()
      close: @sandbox.stub()

    @server = Server(process.cwd())
    @app    = @server.app

  afterEach ->
    @sandbox.restore()

    Settings.remove(process.cwd())

  it "returns a socket instance", ->
    s = Socket(@io, @app)
    expect(s).to.be.instanceof Socket

  it "throws without io instance", ->
    fn = => Socket(null, @app)
    expect(fn).to.throw "Instantiating lib/socket requires an io instance!"

  it "throws without app", ->
    fn = => Socket(@io, null)
    expect(fn).to.throw "Instantiating lib/socket requires an app!"

  context "#close", ->
    beforeEach ->
      @socket = Socket(@io, @app)

    it "calls close on #io", ->
      @socket.close()
      expect(@io.close).to.be.called

    it "calls close on the watchedFiles", ->
      @socket.startListening().then =>
        closeWatchers = @sandbox.spy @socket, "closeWatchers"

        @socket.close()

        expect(closeWatchers).to.be.called

  context "#closeWatchers", ->
    beforeEach ->
      @socket = Socket(@io, @app)

    it "calls close on #watchedTestFile", ->
      close = @sandbox.stub()
      @socket.watchedTestFile = {close: close}
      @socket.closeWatchers()
      expect(close).to.be.calledOnce

    it "is noop without #watchedTestFile", ->
      expect(@socket.closeWatchers()).to.be.undefined

  context "#watchTestFileByPath", ->
    beforeEach ->
      @socket          = Socket(@io, @app)
      @socket.testsDir = Fixtures.project "todos/tests"
      @filePath        = @socket.testsDir + "/test1.js"

      Fixtures.scaffold()

    afterEach ->
      @socket.close()
      Fixtures.remove()

    it "returns undefined if #testFilePath matches arguments", ->
      @socket.testFilePath = @filePath
      expect(@socket.watchTestFileByPath("test1.js")).to.be.undefined

    it "closes existing watchedTestFile", ->
      close = @sandbox.stub()
      @socket.watchedTestFile = {close: close}
      @socket.watchTestFileByPath "test1.js"
      expect(close).to.be.called

    it "sets #testFilePath", ->
      @socket.watchTestFileByPath("test1.js")
      expect(@socket.testFilePath).to.eq @filePath

    it "can normalizes leading slash", ->
      @socket.watchTestFileByPath("/test1.js")
      expect(@socket.testFilePath).to.eq @filePath

    it "watches file by path", (done) ->
      ## chokidar may take 100ms to pick up the file changes
      ## so we just override onTestFileChange and whenever
      ## its invoked we finish the test
      onTestFileChange = @sandbox.stub @socket, "onTestFileChange", -> done()

      @socket.watchTestFileByPath("test1.js").bind(@).then ->
        touch @filePath

  context "#startListening", ->
    beforeEach ->
      @socket = Socket(@io, @app)
      Fixtures.scaffold()

    afterEach ->
      @socket.close()
      Fixtures.remove()

    it "creates testFolder if does not exist", ->
      @server.setCypressJson {
        projectRoot: Fixtures.project("todos")
        testFolder: "does-not-exist"
      }

      @socket.startListening().then ->
        dir = fs.statSync(Fixtures.project("todos") + "/does-not-exist")
        expect(dir.isDirectory()).to.be.true

    it "sets #testsDir", ->
      @server.setCypressJson {
        projectRoot: Fixtures.project("todos")
        testFolder: "does-not-exist"
      }

      @socket.startListening().then ->
        expect(@testsDir).to.eq Fixtures.project("todos/does-not-exist")

    it "listens for app close event once", ->
      close = @sandbox.spy @socket, "close"

      @socket.startListening().then ->
        @app.emit("close")
        @app.emit("close")

        expect(close).to.be.calledOnce

    describe "watch:test:file", ->
      it "listens for watch:test:file event", ->
        @socket.startListening().then =>
          expect(@ioSocket.on).to.be.calledWith("watch:test:file")

      it "passes filePath to #watchTestFileByPath", ->
        watchTestFileByPath = @sandbox.stub @socket, "watchTestFileByPath"

        @ioSocket.on.withArgs("watch:test:file").callsArgWith(1, "foo/bar/baz")

        @socket.startListening().then =>
          expect(watchTestFileByPath).to.be.calledWith "foo/bar/baz"

    describe "#onTestFileChange", ->
      beforeEach ->
        @statAsync = @sandbox.spy(fs, "statAsync")

        @server.setCypressJson {
          projectRoot: Fixtures.project("todos")
          testFolder: "tests"
        }

      it "does not emit if in editFileMode", ->
        @app.enable("editFileMode")

        @socket.onTestFileChange("foo/bar/baz")
        expect(@statAsync).not.to.be.called

      it "does not emit if not a js or coffee files", ->
        @socket.onTestFileChange("foo/bar")
        expect(@statAsync).not.to.be.called

      it "does not emit if a tmp file", ->
        @socket.onTestFileChange("foo/subl-123.js.tmp")
        expect(@statAsync).not.to.be.called

      it "calls statAsync on .js file", ->
        @socket.onTestFileChange("foo/bar.js").catch(->).then =>
          expect(@statAsync).to.be.calledWith("foo/bar.js")

      it "calls statAsync on .coffee file", ->
        @socket.onTestFileChange("foo/bar.coffee").then =>
          expect(@statAsync).to.be.calledWith("foo/bar.coffee")

      it "does not emit if stat throws", ->
        @socket.onTestFileChange("foo/bar.js").then =>
          expect(@io.emit).not.to.be.called

      it "emits 'generate:ids:for:test'", ->
        p = Fixtures.project("todos") + "/tests/test1.js"
        @socket.onTestFileChange(p).then =>
          expect(@io.emit).to.be.calledWith("generate:ids:for:test", "tests/test1.js", "test1.js")

  context "#_runSauce", ->
    beforeEach ->
      @socket = Socket(@io, @app)
      @sauce  = @sandbox.stub(@socket, "sauce").resolves()
      @sandbox.stub(Date, "now").returns(10000000)
      @sandbox.stub(@socket.uuid, "v4").returns("abc123-edfg2323")

    afterEach ->
      @socket.close()

    it "calls callback with jobName and batchId", ->
      fn = @sandbox.stub()
      @socket._runSauce @ioSocket, "app_spec.coffee", fn
      expect(fn).to.be.calledWith "tests/app_spec.coffee", 10000000

    it "emits 'sauce:job:create' with client options", ->
      fn = @sandbox.stub()
      @socket._runSauce @ioSocket, "app_spec.coffee", fn
      expect(@ioSocket.emit).to.be.calledWith "sauce:job:create", {
        batchId: 10000000
        browser: "ie"
        guid: "abc123-edfg2323"
        name: "tests/app_spec.coffee"
        os: "Windows 8.1"
        version: 11
      }

    it "passes options to sauce", ->
      fn = @sandbox.stub()
      @socket._runSauce @ioSocket, "app_spec.coffee", fn
      options = @sauce.getCall(0).args[0]
      expect(options).to.deep.eq {
        url: "http://localhost:2020/__/#/tests/app_spec.coffee?nav=false"
        batchId: 10000000
        guid: "abc123-edfg2323"
        browserName: options.browserName
        version:     options.version
        platform:    options.platform
        onStart:     options.onStart
      }