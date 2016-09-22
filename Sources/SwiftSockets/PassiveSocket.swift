//
//  PassiveSocket.swift
//  SwiftSockets
//
//  Created by Helge Hess on 6/11/14.
//  Copyright (c) 2014-2015 Always Right Institute. All rights reserved.
//

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Dispatch

public typealias PassiveSocketIPv4 = PassiveSocket<sockaddr_in>

/*
 * Represents a STREAM server socket based on the standard Unix sockets library.
 *
 * A passive socket has exactly one address, the address the socket is bound to.
 * If you do not bind the socket, the address is determined after the listen()
 * call was executed through the getsockname() call.
 *
 * Note that if the socket is bound it's still an active socket from the
 * system's PoV, it becomes an passive one when the listen call is executed.
 *
 * Sample:
 *
 *   let socket = PassiveSocket(address: sockaddr_in(port: 4242))
 *
 *   socket.listen(dispatch_get_global_queue(0, 0), backlog: 5) {
 *     print("Wait, someone is attempting to talk to me!")
 *     $0.close()
 *     print("All good, go ahead!")
 *   }
 */
public class PassiveSocket<T: SocketAddress>: Socket<T> {
  
  public var backlog      : Int? = nil
  public var isListening  : Bool { return backlog != nil }
  public var listenSource : dispatch_source_t? = nil
  
  /* init */
  // The overloading behaviour gets more weird every release?

  override public init(fd: FileDescriptor) {
    // required, otherwise the convenience one fails to compile
    super.init(fd: fd)
  }
  
  public convenience init?(address: T) {
    // does not work anymore in b5?: I again need to copy&paste
    // self.init(type: SOCK_STREAM)
    // DUPE:
    let lfd = xsys.socket(T.domain, xsys.SOCK_STREAM, 0)
    guard lfd != -1 else { return nil }

    self.init(fd: FileDescriptor(lfd))
    
    if isValid {
      reuseAddress = true
      if !bind(address) {
        close()
        return nil
      }
    }
  }
  
  /* proper close */
  
  override public func close() {
    if listenSource != nil {
      dispatch_source_cancel(listenSource!)
      listenSource = nil
    }
    super.close()
  }
  
  /* start listening */
  
  public func listen(backlog bl: Int = 5) -> Bool {
    guard isValid      else { return false }
    guard !isListening else { return true }
    
    let rc = xsys.listen(fd.fd, Int32(bl))
    guard rc == 0 else { return false }
    
    self.backlog       = bl
    self.isNonBlocking = true
    return true
  }
  
  public func listen(queue q: dispatch_queue_t, backlog: Int = 5,
                     accept: ( ActiveSocket<T> ) -> Void)
    -> Bool
  {
    guard fd.isValid   else { return false }
    guard !isListening else { return false }
    
    /* setup GCD dispatch source */

#if os(Linux) // is this GCD Linux vs GCD OSX or Swift 2.1 vs 2.2?
#if swift(>=3.0)
    let listenSource = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_READ,
      UInt(fd.fd), // is this going to bite us?
      0,
      q
    )!
#else
    let listenSource = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_READ,
      UInt(fd.fd), // is this going to bite us?
      0,
      q
    )
#endif
#else // os(Darwin)
    let listenSource = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_READ,
      UInt(fd.fd), // is this going to bite us?
      0,
      q
    )
#endif // os(Darwin)
    
    let lfd = fd.fd
    
    listenSource.onEvent { _, _ in
      repeat {
        // FIXME: tried to encapsulate this in a sockaddrbuf which does all
        //        the ptr handling, but it ain't work (autoreleasepool issue?)
        var baddr    = T()
        var baddrlen = socklen_t(baddr.len)
        
        let newFD = withUnsafeMutablePointer(&baddr) {
          ptr -> Int32 in
          let bptr = UnsafeMutablePointer<sockaddr>(ptr) // cast
          return xsys.accept(lfd, bptr, &baddrlen);// buflenptr)
        }
        
        if newFD != -1 {
          // we pass over the queue, seems convenient. Not sure what kind of
          // queue setup a typical server would want to have
          let newSocket = ActiveSocket<T>(fd: FileDescriptor(newFD),
                                          remoteAddress: baddr, queue: q)
          newSocket.isSigPipeDisabled = true // Note: not on Linux!
          
          accept(newSocket)
        }
        else if errno == EWOULDBLOCK {
          break
        }
        else { // great logging as Paul says
          print("Failed to accept() socket: \(self) \(errno)")
        }
        
      }
      while true
    }

    // cannot convert value of type 'dispatch_source_t' (aka 'COpaquePointer')
    // to expected argument type 'dispatch_object_t'
#if os(Linux)
    // TBD: what is the better way?
#if swift(>=3.0)
    dispatch_resume(unsafeBitCast(listenSource, to: dispatch_object_t.self))
#else
    dispatch_resume(unsafeBitCast(listenSource, dispatch_object_t.self))
#endif
#else /* os(Darwin) */
    dispatch_resume(listenSource)
#endif /* os(Darwin) */
    
    guard listen(backlog: backlog) else {
      dispatch_source_cancel(listenSource)
      return false
    }
    
    return true
  }
  
  
  /* description */
  
  override func descriptionAttributes() -> String {
    var s = super.descriptionAttributes()
    if isListening {
      s += " listening"
    }
    return s
  }
}
