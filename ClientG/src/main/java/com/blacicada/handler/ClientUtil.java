package com.blacicada.handler;

import com.blacicada.common.init.ClientInit;

import java.util.HashSet;

public class ClientUtil {
    private static HashSet<Integer> urls= ClientInit.urls;
    private static HashSet<Integer> urlMatch = new HashSet<>();
    private static HashSet<Integer> urlNoMatch = new HashSet<>();
    static boolean urlMatch(String url)  {
        int urlHashCode = url.hashCode();
        boolean match = urlMatch.contains(urlHashCode);
        boolean noMatch = urlNoMatch.contains(urlHashCode);
        // 判断这个url是否是第一次而未被记录
        if (!match && !noMatch) {
            String[] split = url
                    .split("\\.");
            String s = "";
            for (int i = split.length - 1; i >= 0; i--) {
                s = split[i]+s;
                int hashCode = s.hashCode();
                if (urls.contains(hashCode)) {
                    urlMatch.add(urlHashCode);
                    return true;
                }
            }
            if (!urlMatch.contains(urlHashCode)) {
                urlNoMatch.add(urlHashCode);
            }
        }
        return match;
    }
}
