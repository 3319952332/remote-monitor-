import java.util.zip.*;
import java.io.*;

public class ReadZip {
  public static void main(String[] a) throws Exception {
    File f = new File(a[0]);
    System.out.println("file size: " + f.length());
    try (ZipFile zf = new ZipFile(f)) {
      System.out.println("entries: " + zf.size());
      var e = zf.entries();
      while (e.hasMoreElements()) {
        ZipEntry en = e.nextElement();
        System.out.println("  " + en.getName() + " size=" + en.getSize());
      }
      System.out.println("READ OK");
    } catch (Exception ex) {
      System.out.println("READ FAILED: " + ex.getClass().getName() + ": " + ex.getMessage());
      ex.printStackTrace();
    }
  }
}
